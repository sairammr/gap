// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title ShipMany
/// @notice Makes Gap a real two-sided market: ships THREE competing maker strategies into
///         Aqua against the deployed `GapOptionsApp`, each at a different implied vol.
/// @dev No CLOB, no maker bots, no registry — Aqua already is the order book. Each `ship`
///      emits `IAqua.Shipped(maker, app, strategyHash, strategy)` carrying the full
///      abi-encoded `Strategy`, so the whole maker set is recoverable from logs alone.
///      `GapOptionsApp.quoteBest` then picks the cheapest solvent one.
///
///      `quotePremium` ignores `s.maker`, so the ONLY thing separating these three quotes is
///      `volWad`. Implied vol is the competitive axis.
///
///      Maker 0 is the deployer at 50% IV / salt 1 — byte-identical to the strategy
///      `Ship.s.sol` ships and `E2E.s.sol` trades, so `e2e.sh` works straight off this script.
///      Makers 1 and 2 are deterministic throwaway EOAs funded with gas and mock USDC from
///      the deployer.
///
///      `ShipMany` therefore SUBSUMES `Ship` — they are alternatives on a fresh deploy, not a
///      sequence. Aqua strategies are immutable (`ship` reverts `StrategiesMustBeImmutable` on
///      a hash it already holds), so running `Ship.s.sol` after this one reverts on maker 0's
///      hash. That is Aqua enforcing its own invariant, and `Ship.s.sol` is unchanged and
///      still correct when run alone.
///
///      LOAD-BEARING: every maker ends with BOTH an Aqua commitment AND a wallet balance
///      behind it. `ship` writes an accounting entry only; the ERC-20 moves at `pull` time out
///      of the maker's own wallet. Shipping without the wallet backing produces a maker who
///      looks fully collateralised on Aqua's books and reverts `ERC20InsufficientBalance`
///      inside `buyOption`. See `GapOptionsApp.makerCapacity`.
///
///        forge script script/ShipMany.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
contract ShipMany is Script {
    uint256 internal constant N = 3;

    /// @dev Collateral each maker commits to Aqua (6dp USDC).
    uint256 internal constant COLLATERAL_USDC = 100_000e6;
    /// @dev Wallet floor each maker keeps, so every commitment is actually honourable.
    uint256 internal constant WALLET_USDC = 500_000e6;
    /// @dev Gas float for the derived makers (they must send their own approve + ship).
    uint256 internal constant MAKER_GAS = 0.002 ether;

    uint8 internal constant UNDERLYING_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;

    string internal constant DEPLOY_JSON = "./deployments/base-sepolia.json";

    struct Env {
        address aqua;
        address app;
        address nvdax;
        address usdc;
        bytes32 poolId;
        bool underlyingIsCurrency0;
    }

    function run() external {
        Env memory e = _readEnv();
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        uint256[N] memory pks = [deployerPk, uint256(keccak256("gap-maker-2")), uint256(keccak256("gap-maker-3"))];
        // 45% / 50% / 60% IV. Deployer stays at 50% + salt 1 to match Ship.s.sol and E2E.s.sol.
        uint256[N] memory vols = [uint256(0.50e18), uint256(0.45e18), uint256(0.60e18)];
        bytes32[N] memory salts =
            [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))];

        _fundMakers(e, deployerPk, pks);

        string memory makersJson = "[";
        for (uint256 i; i < N; ++i) {
            address maker = vm.addr(pks[i]);
            bytes32 hash = _shipOne(e, pks[i], vols[i], salts[i]);
            makersJson = string.concat(
                makersJson,
                i == 0 ? "" : ",",
                '{"address":"', vm.toString(maker),
                '","volWad":"', vm.toString(vols[i]),
                '","salt":"', vm.toString(salts[i]),
                '"}'
            );
            console2.log("maker", i, maker);
            console2.log("  volWad", vols[i]);
            console2.logBytes32(hash);
        }
        makersJson = string.concat(makersJson, "]");

        vm.writeJson(makersJson, DEPLOY_JSON, ".makers");
        console2.log("wrote .makers into", DEPLOY_JSON);
    }

    /// @dev Deployer gives the derived makers gas, and tops every maker's USDC wallet to
    ///      `WALLET_USDC`. The mock mints permissionlessly, which is why this is cheap.
    function _fundMakers(Env memory e, uint256 deployerPk, uint256[N] memory pks) internal {
        vm.startBroadcast(deployerPk);
        for (uint256 i; i < N; ++i) {
            address maker = vm.addr(pks[i]);
            if (i != 0 && maker.balance < MAKER_GAS) {
                payable(maker).transfer(MAKER_GAS - maker.balance);
            }
            uint256 bal = IERC20(e.usdc).balanceOf(maker);
            if (bal < WALLET_USDC) MockERC20(e.usdc).mint(maker, WALLET_USDC - bal);
        }
        vm.stopBroadcast();
    }

    /// @dev One maker's approve + ship, in its own frame to keep the stack shallow.
    function _shipOne(Env memory e, uint256 pk, uint256 volWad, bytes32 salt) internal returns (bytes32 hash) {
        GapOptionsApp.Strategy memory s = GapOptionsApp.Strategy({
            app: e.app,
            maker: vm.addr(pk),
            underlying: e.nvdax,
            quote: e.usdc,
            poolId: e.poolId,
            underlyingIsCurrency0: e.underlyingIsCurrency0,
            underlyingDecimals: UNDERLYING_DECIMALS,
            quoteDecimals: QUOTE_DECIMALS,
            volWad: volWad,
            salt: salt
        });

        hash = GapOptionsApp(e.app).hashStrategy(s);

        // Aqua strategies are immutable: `ship` requires `tokensCount == 0` and reverts
        // `StrategiesMustBeImmutable` on a re-ship of the same hash. `tokensCount` — not the
        // balance — is the existence flag, so this still skips a strategy that has been fully
        // drawn down. Honour it rather than work around it, and the script stays re-runnable
        // instead of hard-reverting halfway through and leaving a partly-shipped market.
        (, uint8 tokensCount) = IAqua(e.aqua).rawBalances(vm.addr(pk), e.app, hash, e.usdc);
        if (tokensCount != 0) {
            console2.log("  already shipped on Aqua - skipping");
            return hash;
        }

        address[] memory tokens = new address[](1);
        tokens[0] = e.usdc;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COLLATERAL_USDC;

        vm.startBroadcast(pk);
        IERC20(e.usdc).approve(e.aqua, COLLATERAL_USDC);
        bytes32 shipped = IAqua(e.aqua).ship(e.app, abi.encode(s), tokens, amounts);
        vm.stopBroadcast();

        // The Aqua-returned hash MUST equal the app's own hashStrategy of the same struct,
        // or the frontend's rebuilt tuple will point at collateral that does not exist.
        require(shipped == hash, "strategyHash != app.hashStrategy");
    }

    function _readEnv() internal view returns (Env memory e) {
        string memory json = vm.readFile(DEPLOY_JSON);
        e.aqua = vm.parseJsonAddress(json, ".aqua");
        e.app = vm.parseJsonAddress(json, ".gapOptionsApp");
        e.nvdax = vm.parseJsonAddress(json, ".nvdax");
        e.usdc = vm.parseJsonAddress(json, ".usdc");
        e.poolId = vm.parseJsonBytes32(json, ".poolId");
        e.underlyingIsCurrency0 = vm.parseJsonBool(json, ".underlyingIsCurrency0");
    }
}
