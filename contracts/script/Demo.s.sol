// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {IGapOptionCallback} from "../src/interfaces/IGapOptionCallback.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Self-contained taker: pays the option premium by pushing USDC into the
///         maker's Aqua balance during the buyOption callback. Mirrors TakerStub.
contract DemoTaker is IGapOptionCallback {
    IAqua public immutable aqua;
    address public immutable app;

    constructor(IAqua aqua_, address app_) {
        aqua = aqua_;
        app = app_;
    }

    /// @dev takerData = abi.encode(maker, strategyHash).
    function gapOptionCallback(address, address quoteToken, uint256 premiumOwed, bytes calldata takerData)
        external
        override
    {
        (address maker, bytes32 strategyHash) = abi.decode(takerData, (address, bytes32));
        IERC20(quoteToken).approve(address(aqua), premiumOwed);
        aqua.push(maker, app, strategyHash, quoteToken, premiumOwed);
    }

    /// @notice Drive buyOption from the taker so msg.sender implements the callback.
    function buy(
        GapOptionsApp gapApp,
        GapOptionsApp.Strategy calldata s,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size,
        uint256 maxPremium,
        address to,
        bytes calldata takerData
    ) external returns (uint256 positionId) {
        positionId = gapApp.buyOption(s, kind, strike, cap, expiry, size, maxPremium, to, takerData);
    }
}

/// @title Demo
/// @notice End-to-end demo on Base Sepolia: one `buyOption` then one `settle`, using
///         the live-shipped maker strategy. Reads addresses from the deployment JSON.
/// @dev HARD-GATED: this is written to COMPILE and be fork-simulated only. Do NOT run
///      with `--broadcast` until the user confirms `.env` creds are in place. Settlement
///      here is permissionless and reads the real v4 spot through StateView, so the demo
///      must run after `DeployGap` (seeds the pool) and `Ship` (ships USDC collateral).
contract Demo is Script {
    // Option terms for the demo (CALL, ~ATM, small size).
    uint8 internal constant KIND_CALL = 0;
    uint256 internal constant STRIKE = 100e18;
    uint256 internal constant CAP = 5e18;
    uint256 internal constant SIZE = 1e18; // capBacking = 5*1/1e30 scaled = 5e6 USDC
    uint256 internal constant MAX_PREMIUM = 50e6; // 50 USDC ceiling
    uint256 internal constant EXPIRY_OFFSET = 1 days;

    // Strategy constants — MUST match Ship.s.sol so the shipped strategy hash lines up.
    uint8 internal constant UNDERLYING_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;
    uint256 internal constant VOL_WAD = 0.5e18;
    bytes32 internal constant SALT = bytes32(uint256(1));

    struct Env {
        address aqua;
        address app;
        address nvdax;
        address usdc;
        bytes32 poolId;
        bool underlyingIsCurrency0;
        address maker;
    }

    function run() external {
        Env memory e = _readEnv();

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            e.maker = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            e.maker = msg.sender;
            vm.startBroadcast();
        }

        GapOptionsApp gapApp = GapOptionsApp(e.app);
        GapOptionsApp.Strategy memory s = _strategy(e);
        bytes32 hash = gapApp.hashStrategy(s);

        // Deploy the taker and fund it with USDC to pay the premium.
        DemoTaker taker = new DemoTaker(IAqua(e.aqua), e.app);
        MockERC20(e.usdc).mint(address(taker), MAX_PREMIUM);

        uint64 expiry = uint64(block.timestamp + EXPIRY_OFFSET);
        bytes memory takerData = abi.encode(e.maker, hash);
        address holder = e.maker; // demo: maker also receives the position

        uint256 positionId = taker.buy(gapApp, s, KIND_CALL, STRIKE, CAP, expiry, SIZE, MAX_PREMIUM, holder, takerData);
        console2.log("Bought positionId:", positionId);

        // Settle after expiry. In a live run this is a separate tx post-expiry; under
        // fork simulation we warp. vm.warp has no effect once broadcasting on-chain —
        // for the real live demo, invoke settle in a later tx past expiry.
        vm.warp(block.timestamp + EXPIRY_OFFSET + 1);
        gapApp.settle(s, positionId, holder);
        console2.log("Settled positionId:", positionId);

        vm.stopBroadcast();
    }

    function _strategy(Env memory e) internal pure returns (GapOptionsApp.Strategy memory s) {
        s = GapOptionsApp.Strategy({
            app: e.app,
            maker: e.maker,
            underlying: e.nvdax,
            quote: e.usdc,
            poolId: e.poolId,
            underlyingIsCurrency0: e.underlyingIsCurrency0,
            underlyingDecimals: UNDERLYING_DECIMALS,
            quoteDecimals: QUOTE_DECIMALS,
            volWad: VOL_WAD,
            salt: SALT
        });
    }

    function _readEnv() internal view returns (Env memory e) {
        string memory json = vm.readFile("./deployments/base-sepolia.json");
        e.aqua = vm.parseJsonAddress(json, ".aqua");
        e.app = vm.parseJsonAddress(json, ".gapOptionsApp");
        e.nvdax = vm.parseJsonAddress(json, ".nvdax");
        e.usdc = vm.parseJsonAddress(json, ".usdc");
        e.poolId = vm.parseJsonBytes32(json, ".poolId");
        e.underlyingIsCurrency0 = vm.parseJsonBool(json, ".underlyingIsCurrency0");
    }
}
