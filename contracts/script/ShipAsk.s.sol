// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import {WeekendDesk} from "../src/desk/WeekendDesk.sol";
import {WeekendOptions} from "../src/WeekendOptions.sol";
import {OrderLib} from "../test/helpers/OrderLib.sol";

/// @dev Just the one view we cross-check against. `OrderLib.Order` is field-identical to the
///      fork's `ISwapVM.Order` (`MakerTraits` is a user-defined value type over `uint256`, so it
///      ABI-encodes the same), which is what makes `keccak256(abi.encode(order))` equal
///      `SwapVM.hash(order)` on the Aqua path — and therefore equal the `strategyHash` that
///      `Aqua.ship` derives from those same bytes. `_preflight` re-checks that against the live
///      router whenever one is reachable, so a drift cannot survive a dry run.
interface ISwapVMHash {
    function hash(OrderLib.Order calldata order) external view returns (bytes32);
}

/// @title ShipBase
/// @notice Everything `ShipAsk` and `ShipBid` share. One encoder, so the two sides of a
///         maker's book cannot drift apart and produce two differently-hashed orders.
///
/// @dev DRY RUN ONLY. Nothing here broadcasts, deploys or writes. The scripts resolve the
///      config, build the exact order, derive the `strategyHash`, run every pre-flight check
///      that can be run from a view, and print the `approve` + `ship` calldata the maker has to
///      execute. Sending it is a separate, deliberate act.
///
/// @dev WHY IT ONLY PRINTS CALLDATA. Aqua keys balances by `msg.sender`
///      (`_balances[msg.sender][app][strategyHash][token]`) and `SwapVM` reads them back with
///      `AQUA.safeBalances(order.maker, ...)`. So `ship` has to be called **by `order.maker`**,
///      which is the `WeekendDesk` contract itself — not by the EOA running this script. The
///      desk has to forward the call; a script cannot do it for them.
abstract contract ShipBase is Script {
    /// @dev `WeekendPricer.SIDE_ASK` / `SIDE_BID`.
    uint8 internal constant SIDE_ASK = 0;
    uint8 internal constant SIDE_BID = 1;

    string internal constant JSON_PATH = "./deployments/base-sepolia.json";

    struct Config {
        IAqua aqua;
        address router;
        address quote;
        address desk;
        address pricer;
        address optionToken;
        uint256 seriesId;
        uint256 volWad;
        uint16 minPremiumBps;
        uint16 strategyMinPremiumBps;
        bytes32 salt;
        uint40 deadline;
        uint64 rateA;
        uint64 rateB;
        uint256 amount;
    }

    /// @notice The quote would be allowed to price below the floor the core will later enforce.
    error PremiumFloorInversion(uint16 orderBps, uint16 strategyBps);
    /// @notice This exact order hash already has balances in Aqua. Strategies are immutable.
    error AlreadyShipped(bytes32 strategyHash, address token);
    /// @notice A cap of zero is an order that can never fill.
    error ZeroShipAmount();
    /// @notice The locally-derived hash disagrees with the live router's.
    error HashDrift(bytes32 derived, bytes32 onchain);
    /// @notice Quote and option token are the same address; that is not a tradeable pair.
    error NotAPair(address token);
    /// @notice Bps must fit the core's `uint16 minPremiumBps` and stay under 100%.
    error BadBps(uint256 bps);

    // ------------------------------------------------------------------ config

    function _config(uint256 defaultVolWad, string memory amountEnv)
        internal
        view
        returns (Config memory c)
    {
        string memory json = _json();

        c.aqua = IAqua(_address(json, ".aqua", "AQUA"));
        c.router = _address(json, ".swapVmRouter", "SWAPVM_ROUTER");
        c.quote = _address(json, ".usdc", "QUOTE");
        c.desk = _address("", "", "DESK");
        c.pricer = _address("", "", "PRICER");
        c.optionToken = _address("", "", "OPTION_TOKEN");

        c.seriesId = vm.envOr("SERIES_ID", uint256(0));
        c.volWad = vm.envOr("VOL_WAD", defaultVolWad);
        c.minPremiumBps = _bps(vm.envOr("MIN_PREMIUM_BPS", uint256(25)));
        c.strategyMinPremiumBps = _strategyFloorBps(c.desk);
        // No default either. A reused salt is the single thing that makes a ship unrepeatable,
        // so it is never implicit.
        c.salt = vm.envBytes32("SALT");
        c.deadline = uint40(vm.envOr("DEADLINE", block.timestamp + 7 days));
        // 0/0 disables the rate guard. The binding price floor on this route is
        // `minPremiumBps`, enforced inside `WeekendPricer`; `RequireMinRate` is a blunt
        // cross-decimal ratio and a naive 1/1 would reject every sane 6dp-for-18dp fill.
        c.rateA = uint64(vm.envOr("MIN_RATE_A", uint256(0)));
        c.rateB = uint64(vm.envOr("MIN_RATE_B", uint256(0)));
        c.amount = vm.envUint(amountEnv);
    }

    function _json() internal view returns (string memory) {
        try vm.readFile(JSON_PATH) returns (string memory s) {
            return s;
        } catch {
            console2.log("no", JSON_PATH, "- every address must come from the environment");
            return "";
        }
    }

    /// @dev Env always wins over the file. That file is a historical record of an earlier
    ///      deploy and several of its keys point at contracts that no longer exist.
    function _address(string memory json, string memory key, string memory env)
        internal
        view
        returns (address a)
    {
        a = vm.envOr(env, address(0));
        if (a != address(0)) return a;
        if (bytes(json).length != 0 && vm.keyExistsJson(json, key)) {
            a = vm.parseJsonAddress(json, key);
            if (a != address(0)) return a;
        }
        revert(
            bytes(key).length == 0
                ? string.concat("ship: missing address - set ", env)
                : string.concat("ship: missing address - set ", env, ", or ", key, " in ", JSON_PATH)
        );
    }

    /// @notice The `minPremiumBps` of the `WeekendOptions.Strategy` the desk writes against.
    /// @dev Read off the deployed desk when there is one, because that is the number
    ///      `buyOption` will actually enforce mid-fill. `STRATEGY_MIN_PREMIUM_BPS` is only a
    ///      fallback for planning a ship before the desk exists, and if both are present the
    ///      chain wins and a disagreement is reported rather than silently resolved.
    function _strategyFloorBps(address desk) internal view returns (uint16) {
        uint256 declared = vm.envOr("STRATEGY_MIN_PREMIUM_BPS", type(uint256).max);

        if (desk.code.length != 0) {
            try WeekendDesk(desk).ownStrategy() returns (WeekendOptions.Strategy memory s) {
                if (declared != type(uint256).max && declared != s.minPremiumBps) {
                    console2.log("  !!  STRATEGY_MIN_PREMIUM_BPS disagrees with the desk's own");
                    console2.log("  !!  strategy; using the on-chain value. env / chain:", declared, uint256(s.minPremiumBps));
                }
                return s.minPremiumBps;
            } catch {
                console2.log("  --  desk has no readable ownStrategy(); falling back to env");
            }
        }

        if (declared == type(uint256).max) {
            revert(
                "ship: cannot read the backing strategy's floor - deploy and setOwnStrategy on DESK,"
                " or set STRATEGY_MIN_PREMIUM_BPS to its minPremiumBps"
            );
        }
        return _bps(declared);
    }

    function _bps(uint256 bps) internal pure returns (uint16) {
        if (bps > 10_000) revert BadBps(bps);
        return uint16(bps);
    }

    // ------------------------------------------------------------------ the ship plan

    function _report(string memory label, Config memory c, uint8 side)
        internal
        view
        returns (bytes32 strategyHash)
    {
        if (c.amount == 0) revert ZeroShipAmount();
        // `MakerTraitsLib.build` requires `tokenA < tokenB`; equal tokens are not a pair.
        if (c.quote == c.optionToken) revert NotAPair(c.quote);

        // THE DIRECTIONAL INVARIANT. The order's floor must be at least the floor of the
        // `WeekendOptions.Strategy` the desk writes against, so the core can only ever be more
        // permissive than the quote. Inverted, `WeekendPricer` accepts a premium that
        // `buyOption` then rejects with `PremiumBelowFloor` — mid-fill, inside `preTransferOut`,
        // with nothing on either side naming the cause. This is the one place it is cheap to
        // catch.
        if (c.minPremiumBps < c.strategyMinPremiumBps) {
            revert PremiumFloorInversion(c.minPremiumBps, c.strategyMinPremiumBps);
        }

        // The same encoder the integration suite proves against, so what a maker ships and what
        // the tests pin are one set of bytes. The pricing args (`seriesId`, `volWad`,
        // `minPremiumBps`, `side`) ride inside the program and are therefore covered by the
        // hash: a maker cannot repoint pricing after shipping.
        OrderLib.Order memory o = OrderLib.order(
            OrderLib.Params({
                desk: c.desk,
                pricer: c.pricer,
                quote: c.quote,
                optionToken: c.optionToken,
                seriesId: c.seriesId,
                volWad: c.volWad,
                minPremiumBps: c.minPremiumBps,
                side: side,
                deadline: c.deadline,
                salt: c.salt,
                minRateA: c.rateA,
                minRateB: c.rateB
            })
        );
        strategyHash = OrderLib.hash(o);

        // Both legs of the pair, always. `AQUA.safeBalances` reverts unless BOTH tokens sit in
        // an active, non-docked strategy, so the zero leg is there to satisfy that lookup and
        // is never a budget.
        (address[] memory tokens, uint256[] memory amounts) = _legs(c, side);

        _logPlan(label, c, o, strategyHash, tokens, amounts);
        _preflight(c, o, strategyHash, tokens, amounts);
        _logImmutabilityWarning(c, amounts[0]);
        _logCalldata(c, o, tokens, amounts);
    }

    function _legs(Config memory c, uint8 side)
        internal
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](2);
        amounts = new uint256[](2);
        if (side == SIDE_ASK) {
            (tokens[0], amounts[0]) = (c.optionToken, c.amount); // the cap the desk can write
            tokens[1] = c.quote; // zero leg
        } else {
            (tokens[0], amounts[0]) = (c.quote, c.amount); // the budget the desk can spend
            tokens[1] = c.optionToken; // zero leg
        }
    }

    // ------------------------------------------------------------------ pre-flight

    /// @dev Every check that can be made without sending anything. Skipped per-contract when
    ///      that contract is not deployed on whatever chain the script is simulating against,
    ///      so a bare `forge script` with no RPC still prints a full plan.
    function _preflight(
        Config memory c,
        OrderLib.Order memory o,
        bytes32 strategyHash,
        address[] memory tokens,
        uint256[] memory amounts
    ) internal view {
        if (c.router.code.length != 0) {
            try ISwapVMHash(c.router).hash(o) returns (bytes32 onchain) {
                if (onchain != strategyHash) revert HashDrift(strategyHash, onchain);
                console2.log("  ok  router.hash(order) == strategyHash");
            } catch {
                console2.log("  --  router.hash(order) unavailable at", c.router);
            }
        } else {
            console2.log("  --  no router code here; hash not cross-checked");
        }

        if (address(c.aqua).code.length != 0) {
            // `Aqua.ship` requires `tokensCount == 0` for every leg. A non-zero count means this
            // exact order was already shipped (or docked), and `StrategiesMustBeImmutable` will
            // reject the re-ship. There is no restock: a new offer needs a new SALT.
            for (uint256 i; i < tokens.length; ++i) {
                (, uint8 count) = c.aqua.rawBalances(c.desk, c.router, strategyHash, tokens[i]);
                if (count != 0) revert AlreadyShipped(strategyHash, tokens[i]);
            }
            console2.log("  ok  strategyHash is unused in Aqua (ship would not hit immutability)");
        } else {
            console2.log("  --  no Aqua code here; immutability not checked");
        }

        // `ship` moves no tokens. `AQUA.pull` is a real `transferFrom` out of the maker's wallet
        // at fill time, so without this approval the books look healthy and every fill reverts
        // with ERC20InsufficientAllowance. On an ask the option tokens do not even exist yet —
        // they are minted inside `preTransferOut` — and minting does not credit the ledger, so
        // the approval has to cover the whole shipped cap up front.
        if (c.desk.code.length == 0) {
            console2.log("  --  no desk code here; Aqua allowance not checked");
        } else if (tokens[0].code.length == 0) {
            console2.log("  --  shipped token is not deployed here; Aqua allowance not checked");
        } else {
            uint256 allowed = IERC20(tokens[0]).allowance(c.desk, address(c.aqua));
            if (allowed < amounts[0]) {
                console2.log("  !!  desk has NOT approved Aqua for the shipped token");
                console2.log("  !!  token:", tokens[0]);
                console2.log("  !!  allowance / needed:", allowed, amounts[0]);
                console2.log("  !!  fix with desk.approveAqua(token, amount) BEFORE the first fill");
            } else {
                console2.log("  ok  desk allowance to Aqua covers the shipped amount");
            }
        }
    }

    // ------------------------------------------------------------------ output

    function _logPlan(
        string memory label,
        Config memory c,
        OrderLib.Order memory o,
        bytes32 strategyHash,
        address[] memory tokens,
        uint256[] memory amounts
    ) internal pure {
        console2.log("================================================================");
        console2.log(string.concat("  DRY RUN - ", label, " - nothing is sent, nothing is signed"));
        console2.log("================================================================");
        console2.log("router (Aqua app) :", c.router);
        console2.log("aqua              :", address(c.aqua));
        console2.log("maker (order.maker):", c.desk);
        console2.log("pricer            :", c.pricer);
        console2.log("quote             :", c.quote);
        console2.log("optionToken       :", c.optionToken);
        console2.log("seriesId          :", c.seriesId);
        console2.log("volWad            :", c.volWad);
        console2.log("minPremiumBps     :", uint256(c.minPremiumBps));
        console2.log("strategy floor bps:", uint256(c.strategyMinPremiumBps));
        console2.log("deadline          :", uint256(c.deadline));
        console2.log("minRate A/B       :", uint256(c.rateA), uint256(c.rateB));
        console2.log("salt              :", vm.toString(c.salt));
        console2.log("");
        console2.log("WOULD SHIP (both legs, always):");
        console2.log("  leg 0 (cap)     :", tokens[0], amounts[0]);
        console2.log("  leg 1 (zero)    :", tokens[1], amounts[1]);
        console2.log("");
        console2.log("strategyHash = SwapVM.hash(order) :", vm.toString(strategyHash));
        console2.log("order.traits                      :", vm.toString(bytes32(o.traits)));
        console2.log("order.data                        :", vm.toString(o.data));
        console2.log("");
        console2.log("checks:");
    }

    function _logImmutabilityWarning(Config memory c, uint256 cap) internal pure {
        console2.log("");
        console2.log("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        console2.log("  !! Aqua.ship is IMMUTABLE (StrategiesMustBeImmutable).");
        console2.log("  !! This amount is a PERMANENT cumulative cap on everything");
        console2.log("  !! this order can EVER sell, across every fill of its hash:");
        console2.log("  !!    ", cap);
        console2.log("  !! There is no restock. Topping up means Aqua.push(), which");
        console2.log("  !! moves real tokens in. Re-offering after exhaustion needs a");
        console2.log("  !! NEW SALT, which is a different order and a different hash.");
        console2.log("  !! Current salt:");
        console2.log("  !!    ", vm.toString(c.salt));
        console2.log("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
    }

    /// @dev `ship` must come from `order.maker` (the desk), so it is printed as calldata for the
    ///      desk to forward rather than executed here.
    function _logCalldata(
        Config memory c,
        OrderLib.Order memory o,
        address[] memory tokens,
        uint256[] memory amounts
    ) internal pure {
        console2.log("");
        console2.log("to execute, the MAKER CONTRACT itself must send, in this order:");
        console2.log("  1. to", tokens[0]);
        console2.log("     approve(aqua, amount) calldata:");
        console2.log("    ", vm.toString(abi.encodeCall(IERC20.approve, (address(c.aqua), amounts[0]))));
        console2.log("  2. to", address(c.aqua));
        console2.log("     ship(router, abi.encode(order), tokens, amounts) calldata:");
        console2.log("    ", vm.toString(abi.encodeCall(IAqua.ship, (c.router, abi.encode(o), tokens, amounts))));
        console2.log("");
        console2.log("  the shipped strategy bytes are abi.encode(order) - the SwapVM Order, NOT");
        console2.log("  a WeekendOptions.Strategy. That is what makes Aqua's strategyHash equal");
        console2.log("  SwapVM's hash(order), so one ledger entry backs exactly one quote.");
        console2.log("================================================================");
    }
}

/// @title ShipAsk
/// @notice Dry-runs the ask side of a Weekend Options quote: the desk offers to WRITE options
///         for quote tokens, minting them just-in-time inside `preTransferOut`.
///
///         Ships `[optionToken @ SERIES_CAP, quote @ 0]`, side `ASK`.
///
/// @dev Run it (no --broadcast, ever):
///
///        DESK=0x.. PRICER=0x.. OPTION_TOKEN=0x.. SERIES_ID=0 \
///        SERIES_CAP=100000000000000000000 STRATEGY_MIN_PREMIUM_BPS=25 \
///        SALT=0x0000000000000000000000000000000000000000000000000000000000000001 \
///          ~/.foundry/bin/forge script script/ShipAsk.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
///
///      Addresses fall back to `deployments/base-sepolia.json`; any of them can be overridden
///      from the environment, and must be when that file is stale.
///
/// @dev A two-sided maker's spread is vol, and nothing else: ship a HIGHER `VOL_WAD` here than
///      on `ShipBid`, or the book is arbitrageable flat on the first round trip.
contract ShipAsk is ShipBase {
    function run() external view returns (bytes32 strategyHash) {
        Config memory c = _config(0.6e18, "SERIES_CAP");
        return _report("ASK (desk writes options for quote)", c, SIDE_ASK);
    }
}
