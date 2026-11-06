// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";

/// @title DeployAqua
/// @notice Deploys a fresh `Aqua` (the shared-liquidity layer) on Base Sepolia,
///         where Aqua is not yet canonically deployed.
/// @dev The runtime codehash is logged and compared to the official 1inch mainnet
///      codehash as a diagnostic only — NEVER reverting. The mainnet bytecode is
///      produced under 1inch's hardhat build (prague / via_ir / 10M optimizer runs),
///      mirrored here by `[profile.aqua]`. A default-profile deploy (used for the
///      live demo) will log a MISMATCH, which is expected and fine.
contract DeployAqua is Script {
    /// @notice Official 1inch Aqua mainnet runtime codehash (reference only).
    bytes32 internal constant AQUA_MAINNET_CODEHASH =
        0x720bc02d220db318164dc3bade86eec1f3655bdc00fc1174de7d816a95c341f8;

    /// @notice Deploy and return the Aqua instance (reused by DeployGap).
    function run() external returns (Aqua aqua) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            // No creds: still deploys under a fork simulation (no broadcast).
            vm.startBroadcast();
        }

        aqua = new Aqua();

        vm.stopBroadcast();

        _logCodehash(address(aqua));
    }

    /// @dev Log-only codehash comparison. Does NOT revert on mismatch.
    function _logCodehash(address aquaAddr) internal view {
        bytes32 actual;
        assembly {
            actual := extcodehash(aquaAddr)
        }
        console2.log("Aqua deployed at:", aquaAddr);
        console2.logBytes32(actual);
        if (actual == AQUA_MAINNET_CODEHASH) {
            console2.log("Aqua codehash MATCH (built under [profile.aqua] prague/via_ir/10M runs)");
        } else {
            console2.log("Aqua codehash MISMATCH vs mainnet (expected under default profile) - OK for demo");
            console2.logBytes32(AQUA_MAINNET_CODEHASH);
        }
    }
}
