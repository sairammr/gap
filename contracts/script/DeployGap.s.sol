// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {PoolSetup} from "./lib/PoolSetup.sol";
import {UniV4Spot} from "../src/lib/UniV4Spot.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Minimal Permit2 surface needed to let the PositionManager pull tokens.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title DeployGap
/// @notice Deploys the Gap options stack on Base Sepolia: mock USDC + mock NVDAx,
///         a fresh Aqua, the `GapOptionsApp`, and a seeded Uniswap v4 NVDAx/USDC pool
///         priced at ~100 USDC/NVDAx. Writes `deployments/base-sepolia.json`.
/// @dev Ruling 5: collateral + settlement token is the MOCK USDC we deploy here, not
///      NVDAx. NVDAx is pricing-only (its v4 spot feeds Black-Scholes). We deploy a
///      mock USDC because Base Sepolia's real Circle USDC cannot be minted by the
///      deployer (so there would be no liquidity to seed / collateral to ship). The
///      real Circle USDC address is still recorded under `circleUsdc` for reference.
///
///      Deploys Aqua INLINE (rather than chaining DeployAqua) so this single script
///      produces a self-consistent JSON; the codehash diagnostic is logged the same way.
contract DeployGap is Script {
    // --- Base Sepolia canonical addresses (chainid 84532) ---
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
    IStateView internal constant STATE_VIEW = IStateView(0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant CIRCLE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    bytes32 internal constant AQUA_MAINNET_CODEHASH =
        0x720bc02d220db318164dc3bade86eec1f3655bdc00fc1174de7d816a95c341f8;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    // Target pool spot: 100 USDC per NVDAx (USDC 6dp, NVDAx 18dp).
    uint256 internal constant TARGET_SPOT_WAD = 100e18;

    // Generous demo liquidity + collateral budgets.
    uint256 internal constant NVDAX_POOL_BUDGET = 1_000_000e18;
    uint256 internal constant USDC_POOL_BUDGET = 100_000_000e6;

    /// @notice Everything the deploy produces, grouped to keep the stack shallow.
    struct Deployed {
        Aqua aqua;
        MockERC20 nvdax;
        MockERC20 usdc;
        GapOptionsApp app;
        bytes32 poolId;
        bool underlyingIsCurrency0;
    }

    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer;
        if (pk != 0) {
            deployer = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            // Fork-simulation fallback: default sender, no creds required.
            deployer = msg.sender;
            vm.startBroadcast();
        }

        d = _deployCore();
        d.underlyingIsCurrency0 = address(d.nvdax) < address(d.usdc);
        d.poolId = _setupPool(d, deployer);

        vm.stopBroadcast();

        _logCodehash(address(d.aqua));
        _writeJson(d);
    }

    /// @dev Deploy Aqua, both mocks, and the app; mint the pool + demo budgets to deployer.
    function _deployCore() internal returns (Deployed memory d) {
        d.aqua = new Aqua();
        d.nvdax = new MockERC20("NVIDIA xStock", "NVDAx", 18);
        d.usdc = new MockERC20("USD Coin", "USDC", 6);
        d.app = new GapOptionsApp(IAqua(address(d.aqua)), STATE_VIEW);

        // Mint generously so there is liquidity to seed the pool AND USDC for the
        // maker to ship as collateral (Ship.s.sol) and for takers to pay premiums.
        d.nvdax.mint(msg.sender, NVDAX_POOL_BUDGET);
        d.usdc.mint(msg.sender, USDC_POOL_BUDGET);
    }

    /// @dev Init the v4 pool at ~100 USDC/NVDAx, then seed a full-range position.
    function _setupPool(Deployed memory d, address deployer) internal returns (bytes32 poolId) {
        uint160 sqrtPriceX96 = _sqrtPriceForSpot(d.underlyingIsCurrency0);

        PoolKey memory key = PoolSetup.initPool(
            POOL_MANAGER,
            d.underlyingIsCurrency0 ? Currency.wrap(address(d.nvdax)) : Currency.wrap(address(d.usdc)),
            d.underlyingIsCurrency0 ? Currency.wrap(address(d.usdc)) : Currency.wrap(address(d.nvdax)),
            FEE,
            TICK_SPACING,
            sqrtPriceX96
        );
        poolId = keccak256(abi.encode(key));

        _seedPool(d, key, sqrtPriceX96, deployer);
    }

    /// @dev Approve both tokens via Permit2 and mint a wide-range liquidity position.
    function _seedPool(Deployed memory d, PoolKey memory key, uint160 sqrtPriceX96, address recipient) internal {
        int24 lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

        _approveViaPermit2(address(d.nvdax));
        _approveViaPermit2(address(d.usdc));

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            d.underlyingIsCurrency0 ? NVDAX_POOL_BUDGET : USDC_POOL_BUDGET,
            d.underlyingIsCurrency0 ? USDC_POOL_BUDGET : NVDAX_POOL_BUDGET
        );
        require(liq > 0, "zero liquidity");

        PoolSetup.seed(POSITION_MANAGER, key, lower, upper, liq, recipient);
    }

    /// @dev Two-step Permit2 grant: ERC20 -> Permit2 (infinite), then Permit2 -> PositionManager.
    function _approveViaPermit2(address token) internal {
        (bool ok,) =
            token.call(abi.encodeWithSignature("approve(address,uint256)", address(PERMIT2), type(uint256).max));
        require(ok, "erc20 approve permit2 failed");
        PERMIT2.approve(token, address(POSITION_MANAGER), type(uint160).max, uint48(block.timestamp + 365 days));
    }

    /// @dev Inverts UniV4Spot.fromSqrtPriceX96 to find the sqrtPriceX96 giving ~100e18.
    ///      underlying = NVDAx (18dp), quote = USDC (6dp). Mirrors PoolFork.t.sol.
    function _sqrtPriceForSpot(bool underlyingIsCurrency0) internal pure returns (uint160) {
        uint256 Q96 = 1 << 96;
        uint256 inner;
        if (underlyingIsCurrency0) {
            // p^2 = spotWad * Q96^2 * 10^6 / (1e18 * 10^18)
            inner = (TARGET_SPOT_WAD * Q96 / 1e18) * Q96 * (10 ** 6) / (10 ** 18);
        } else {
            // p^2 = Q96^2 * 1e18 * 10^18 / (spotWad * 10^6)
            inner = Q96 * Q96 / TARGET_SPOT_WAD * 1e18 / (10 ** 6) * (10 ** 18);
        }
        return uint160(_sqrt(inner));
    }

    /// @dev Babylonian integer sqrt.
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

    /// @dev Log-only Aqua codehash comparison (never reverts).
    function _logCodehash(address aquaAddr) internal view {
        bytes32 actual;
        assembly {
            actual := extcodehash(aquaAddr)
        }
        console2.log("Aqua deployed at:", aquaAddr);
        console2.logBytes32(actual);
        if (actual == AQUA_MAINNET_CODEHASH) {
            console2.log("Aqua codehash MATCH (built under [profile.aqua])");
        } else {
            console2.log("Aqua codehash MISMATCH vs mainnet (expected under default profile) - OK for demo");
        }
    }

    /// @dev Write deployments/base-sepolia.json. `poolId` is the load-bearing key.
    function _writeJson(Deployed memory d) internal {
        string memory obj = "gap";
        vm.serializeAddress(obj, "aqua", address(d.aqua));
        vm.serializeAddress(obj, "gapOptionsApp", address(d.app));
        vm.serializeAddress(obj, "nvdax", address(d.nvdax));
        vm.serializeAddress(obj, "usdc", address(d.usdc));
        vm.serializeAddress(obj, "circleUsdc", CIRCLE_USDC);
        vm.serializeAddress(obj, "poolManager", address(POOL_MANAGER));
        vm.serializeAddress(obj, "positionManager", address(POSITION_MANAGER));
        vm.serializeAddress(obj, "stateView", address(STATE_VIEW));
        vm.serializeBytes32(obj, "poolId", d.poolId);
        string memory json = vm.serializeBool(obj, "underlyingIsCurrency0", d.underlyingIsCurrency0);

        vm.writeJson(json, "./deployments/base-sepolia.json");
        console2.log("Wrote deployments/base-sepolia.json");
    }
}
