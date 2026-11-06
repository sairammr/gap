// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ShipBase} from "./ShipAsk.s.sol";

/// @title ShipBid
/// @notice Dry-runs the bid side of a Weekend Options quote: the desk offers to BUY options
///         back for quote tokens, closing them inside `postTransferIn`.
///
///         Ships `[quote @ BUDGET, optionToken @ 0]`, side `BID`.
///
/// @dev Run it (no --broadcast, ever):
///
///        DESK=0x.. PRICER=0x.. OPTION_TOKEN=0x.. SERIES_ID=0 \
///        BUDGET=10000000000 STRATEGY_MIN_PREMIUM_BPS=25 \
///        SALT=0x0000000000000000000000000000000000000000000000000000000000000002 \
///          ~/.foundry/bin/forge script script/ShipBid.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
///
/// @dev `BUDGET` is in QUOTE units (6dp USDC), not option units — this leg is cash the desk is
///      willing to spend, and like every shipped amount it is a permanent cumulative cap.
///
/// @dev Spread is vol. `VOL_WAD` here defaults BELOW `ShipAsk`'s, and must stay below it: a
///      bid at or above the ask vol is a standing invitation to round-trip the desk flat. The
///      two scripts cannot check each other, so the maker owns this one.
///
/// @dev `minPremiumBps` is inert on this side — `WeekendPricer._enforceFloor` is ask-only,
///      because on a bid the maker is the one paying and a floor there would be a ceiling on
///      their own bid. It is still carried in the program bytes (it is part of the hash), and
///      the ask-side invariant is still asserted so one misconfigured desk cannot ship a bid
///      whose recorded floor contradicts the strategy behind it.
contract ShipBid is ShipBase {
    function run() external view returns (bytes32 strategyHash) {
        Config memory c = _config(0.4e18, "BUDGET");
        return _report("BID (desk buys options back for quote)", c, SIDE_BID);
    }
}
