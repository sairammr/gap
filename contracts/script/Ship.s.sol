// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GapOptionsApp} from "../src/GapOptionsApp.sol";

/// @title Ship
/// @notice Maker ships USDC collateral into Aqua, binding a Gap option-writing
///         strategy to the deployed `GapOptionsApp`.
/// @dev Ruling 5: the shipped asset array is `[usdc]` (the MOCK USDC), NOT NVDAx —
///      the whole system pays/returns USDC and `buyOption` pulls USDC backing. NVDAx
///      is pricing-only. Shipping NVDAx would make the on-chain `AQUA.pull` of USDC
///      revert. Reads addresses from `deployments/base-sepolia.json`.
contract Ship is Script {
    // Maker's USDC collateral budget (6dp). 100k USDC backs many buyOptions
    // (per position, buyOption pulls capBacking = cap*size/1e30 USDC).
    uint256 internal constant COLLATERAL_USDC = 100_000e6;

    // Strategy constants (field order is load-bearing — must match hashStrategy).
    uint8 internal constant UNDERLYING_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;
    uint256 internal constant VOL_WAD = 0.5e18; // 50% IV
    bytes32 internal constant SALT = bytes32(uint256(1));

    function run() external returns (bytes32 strategyHash) {
        // --- read deployment addresses ---
        string memory json = vm.readFile("./deployments/base-sepolia.json");
        address aqua = vm.parseJsonAddress(json, ".aqua");
        address app = vm.parseJsonAddress(json, ".gapOptionsApp");
        address nvdax = vm.parseJsonAddress(json, ".nvdax");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        bytes32 poolId = vm.parseJsonBytes32(json, ".poolId");
        bool underlyingIsCurrency0 = vm.parseJsonBool(json, ".underlyingIsCurrency0");

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address maker;
        if (pk != 0) {
            maker = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            maker = msg.sender;
            vm.startBroadcast();
        }

        GapOptionsApp gapApp = GapOptionsApp(app);
        GapOptionsApp.Strategy memory strategy = GapOptionsApp.Strategy({
            app: app,
            maker: maker,
            underlying: nvdax,
            quote: usdc,
            poolId: poolId,
            underlyingIsCurrency0: underlyingIsCurrency0,
            underlyingDecimals: UNDERLYING_DECIMALS,
            quoteDecimals: QUOTE_DECIMALS,
            volWad: VOL_WAD,
            salt: SALT
        });

        // Maker approves Aqua to pull the USDC collateral, then ships [usdc].
        IERC20(usdc).approve(aqua, COLLATERAL_USDC);

        address[] memory tokens = new address[](1);
        tokens[0] = usdc;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COLLATERAL_USDC;

        strategyHash = IAqua(aqua).ship(app, abi.encode(strategy), tokens, amounts);

        vm.stopBroadcast();

        // The Aqua-returned hash MUST equal the app's own hashStrategy of the same struct.
        bytes32 expected = gapApp.hashStrategy(strategy);
        console2.log("Shipped strategy. strategyHash:");
        console2.logBytes32(strategyHash);
        require(strategyHash == expected, "strategyHash != gapApp.hashStrategy(strategy)");
        console2.log("strategyHash matches gapApp.hashStrategy(strategy)");
    }
}
