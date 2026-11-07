// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import {WeekendDesk} from "../src/desk/WeekendDesk.sol";
import {Kind, WeekendOptions} from "../src/WeekendOptions.sol";
import {OrderLib} from "../test/helpers/OrderLib.sol";

/// @title SeedBook
/// @notice Fills the resting-order book with a strike ladder, so the desk looks like a desk
///         rather than three lonely rows.
///
/// @dev UNLIKE `ShipAsk`/`ShipBid`, THIS ONE BROADCASTS. Those two only print calldata because
///      the EOA running them is not `order.maker` — the maker is the desk, and Aqua keys balances
///      by `msg.sender`. The way through is `WeekendDesk.ship`, which is `onlyOwner` and forwards
///      to `AQUA.ship` so the desk itself is the caller. So this script must be run by the desk's
///      OWNER, and every desk call below goes through that forwarder.
///
/// @dev Idempotent on the series: `createSeries` returns the existing id for an identical
///      (underlying, expiry, kind, strike), so a re-run reuses them. It is NOT idempotent on the
///      ships — a strategy hash that already carries balances reverts, which is why the salt
///      mixes in `RUN`. Bump `RUN` to seed another layer on top of an existing book.
///
/// Usage:
///   forge script script/SeedBook.s.sol --sig 'seed()' --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --broadcast --private-key $PRIVATE_KEY
contract SeedBook is Script {
    uint8 internal constant SIDE_ASK = 0;
    uint8 internal constant SIDE_BID = 1;

    /// @dev Bump to re-seed without colliding with the hashes already shipped.
    uint256 internal constant RUN = 1;

    /// @dev Per-series write cap the desk advertises, and the ask's shipped option cap.
    uint256 internal constant CAP = 50e18;
    /// @dev Per-bid USDC budget (6dp).
    uint256 internal constant BID_BUDGET = 5_000e6;

    /// @dev Vol is the maker's only competitive axis, so the ladder walks a smile: wings wider
    ///      than the body. Bids sit below their ask so the two sides never cross.
    uint256 internal constant VOL_BODY = 0.55e18;
    uint256 internal constant VOL_WING = 0.70e18;
    uint256 internal constant VOL_BID = 0.40e18;

    uint16 internal constant ASK_BPS = 25;
    uint16 internal constant BID_BPS = 1;

    struct Leg {
        Kind kind;
        uint256 strike; // 6dp
        uint64 tenorDays;
        bool withBid;
    }

    function seed() external {
        address app = vm.envAddress("APP");
        address deskAddr = vm.envAddress("DESK");
        address pricer = vm.envAddress("PRICER");
        address router = vm.envAddress("SWAPVM_ROUTER");
        address underlying = vm.envAddress("UNDERLYING");
        address quote = vm.envAddress("QUOTE");

        WeekendOptions options = WeekendOptions(app);
        WeekendDesk desk = WeekendDesk(deskAddr);

        Leg[] memory legs = _ladder();

        vm.startBroadcast();

        // 1. Series. Permissionless, and deduped on (underlying, expiry, kind, strike).
        uint256[] memory ids = new uint256[](legs.length);
        uint256[] memory caps = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            uint64 expiry = uint64(block.timestamp) + legs[i].tenorDays * 1 days;
            ids[i] = options.createSeries(underlying, expiry, legs[i].kind, legs[i].strike);
            caps[i] = CAP;
        }

        // 2. One call lists them all — the desk will not write a series it was not told about.
        desk.listSeries(ids, caps);

        // 3. The quote-token approval is shared by every bid, so it is granted once.
        desk.approveAqua(quote, type(uint256).max);

        // 4. Ship each leg. The ask sells the option token, the bid spends USDC; the other leg
        //    is always present at zero because `safeBalances` reverts unless BOTH tokens sit in
        //    an active strategy.
        for (uint256 i = 0; i < legs.length; i++) {
            address optionToken = address(options.getSeries(ids[i]).token);

            desk.approveAqua(optionToken, type(uint256).max);

            uint256 vol = _vol(legs[i]);
            uint40 deadline = uint40(block.timestamp + legs[i].tenorDays * 1 days);

            _ship(desk, router, OrderLib.Params({
                desk: deskAddr,
                pricer: pricer,
                quote: quote,
                optionToken: optionToken,
                seriesId: ids[i],
                volWad: vol,
                minPremiumBps: ASK_BPS,
                side: SIDE_ASK,
                deadline: deadline,
                salt: _salt(ids[i], SIDE_ASK),
                minRateA: 0,
                minRateB: 0
            }), optionToken, quote, CAP, "ask");

            if (legs[i].withBid) {
                _ship(desk, router, OrderLib.Params({
                    desk: deskAddr,
                    pricer: pricer,
                    quote: quote,
                    optionToken: optionToken,
                    seriesId: ids[i],
                    volWad: VOL_BID,
                    minPremiumBps: BID_BPS,
                    side: SIDE_BID,
                    deadline: deadline,
                    salt: _salt(ids[i], SIDE_BID),
                    minRateA: 0,
                    minRateB: 0
                }), quote, optionToken, BID_BUDGET, "bid");
            }
        }

        vm.stopBroadcast();
    }

    /// @dev Ship one leg and print the row the frontend needs. The log line is the handoff:
    ///      `makerQuotes` in the app reads exactly these fields.
    function _ship(
        WeekendDesk desk,
        address router,
        OrderLib.Params memory p,
        address funded,
        address zeroLeg,
        uint256 amount,
        string memory label
    ) internal {
        OrderLib.Order memory o = OrderLib.order(p);
        bytes32 strategyHash = OrderLib.hash(o);

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (funded, amount);
        tokens[1] = zeroLeg;

        desk.ship(router, abi.encode(o), tokens, amounts);

        console2.log("QUOTE", label);
        console2.log("  seriesId     ", p.seriesId);
        console2.log("  optionToken  ", p.optionToken);
        console2.log("  volWad       ", p.volWad);
        console2.log("  minPremiumBps", uint256(p.minPremiumBps));
        console2.log("  deadline     ", uint256(p.deadline));
        console2.logBytes32(p.salt);
        console2.logBytes32(strategyHash);
    }

    /// @dev Wings are priced wider than the body — a flat vol across a ladder is a tell that
    ///      nothing is really quoting it.
    function _vol(Leg memory l) internal pure returns (uint256) {
        // 180-200 is the body around a ~186 spot; everything outside is a wing.
        if (l.strike >= 180e6 && l.strike <= 200e6) return VOL_BODY;
        return VOL_WING;
    }

    function _salt(uint256 id, uint8 side) internal pure returns (bytes32) {
        return keccak256(abi.encode("gap.seed", RUN, id, side));
    }

    /// @dev The ladder. Strikes bracket a ~186 spot, two tenors so the book has a front and a
    ///      back month, and bids only where a holder would plausibly want out.
    function _ladder() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](9);
        legs[0] = Leg(Kind.CALL, 170e6, 7, true);
        legs[1] = Leg(Kind.CALL, 180e6, 7, true);
        legs[2] = Leg(Kind.CALL, 190e6, 7, false);
        legs[3] = Leg(Kind.CALL, 200e6, 7, false);
        legs[4] = Leg(Kind.CALL, 190e6, 21, false);
        legs[5] = Leg(Kind.PUT, 160e6, 7, false);
        legs[6] = Leg(Kind.PUT, 175e6, 7, true);
        legs[7] = Leg(Kind.PUT, 185e6, 7, true);
        legs[8] = Leg(Kind.PUT, 185e6, 21, false);
    }

}
