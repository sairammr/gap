// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IStaticExtruction, SwapQuery, SwapRegisters } from "../interfaces/IExtruction.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { WeekendOptions, Kind } from "../WeekendOptions.sol";
import { GapPricing } from "../lib/GapPricing.sol";

/// @title WeekendPricer
/// @notice Prices one option series into the SwapVM swap registers, as an `Extruction` (opcode
/// 0x04) target.
///
/// @dev WHY THIS IS NOT AN OPCODE.
/// `AquaOpcodes` ships no WAD transcendental math — its only numeric library is OpenZeppelin
/// `Math`. That is why the in-tree `WeekendGap` opcode prices a linearized Bachelier
/// approximation rather than Black-Scholes. `Extruction` is already wired into `AquaOpcodes`
/// (and both other opcode sets) precisely so maker-chosen logic can run without touching the
/// VM, so the full Abramowitz-Stegun pricing lives here instead: no new opcode, no fork edit,
/// no router redeploy. The already-deployed `AquaSwapVMRouter` can call this contract today.
///
/// @dev SAFETY ENVELOPE, per `Extruction`'s own NatSpec.
/// - **Deterministic and identical in quote and swap mode.** Implemented `view`, so there is no
///   storage to diverge. SwapVM calls `IStaticExtruction` when quoting and `IExtruction` when
///   swapping; both selectors are identical, so this one function serves both.
/// - **Not upgradeable, no admin.** Every dependency is `immutable`. The opcode asks for exactly
///   this, and the target address is baked into the maker's program bytes — which are part of
///   `order.data` and therefore covered by the order hash — so a maker cannot repoint pricing
///   after shipping.
/// - **Maker spend is bounded elsewhere.** This contract never widens `balanceIn`/`balanceOut`;
///   it only fills the one missing amount register. On the Aqua path those balances are preloaded
///   from `AQUA.safeBalances`, which is what caps how much the maker can be drained.
/// - **Taker is protected by their own threshold.** SwapVM enforces the taker's `minOut` after
///   the program runs, so a mispriced curve cannot force a fill.
///
/// @dev DIRECTION IS A SECURITY GATE, NOT A SANITY CHECK.
/// `AquaOpcodes` carries no `LimitSwap`, so nothing validates swap direction for free. An ask
/// order accumulates quote-token balance in the maker's Aqua counter; without this gate that
/// growing counter would be a standing allowance for anyone to fill the *reverse* direction —
/// selling options back to the maker at the maker's own ask price. Each order therefore declares
/// its side and this contract refuses any fill that does not match it.
contract WeekendPricer is IStaticExtruction {
    /// @notice Ask: taker pays quote, receives option tokens. The maker is selling (writing).
    uint8 public constant SIDE_ASK = 0;
    /// @notice Bid: taker delivers option tokens, receives quote. The maker is buying them back.
    uint8 public constant SIDE_BID = 1;

    WeekendOptions public immutable APP;
    IPriceOracle public immutable ORACLE;
    /// @notice The single quote token every series is priced in (6 dp USDC).
    address public immutable QUOTE;
    /// @notice `10 ** (18 - quoteDecimals)`, the quote-units <-> WAD scale factor.
    uint256 public immutable QUOTE_TO_WAD;

    error UnknownSide(uint8 side);
    error WrongSwapDirection(address tokenIn, address tokenOut);
    error WrongSeriesToken(address expected, address actual);
    error SeriesExpired(uint64 expiry);
    error ZeroPremium();
    error PremiumBelowFloor(uint256 premium, uint256 floor);
    error ZeroAmount();

    constructor(WeekendOptions app, IPriceOracle oracle, address quote, uint8 quoteDecimals) {
        APP = app;
        ORACLE = oracle;
        QUOTE = quote;
        QUOTE_TO_WAD = 10 ** (18 - quoteDecimals);
    }

    /// @notice The maker's minimum acceptable premium per 1e18 options, in quote units.
    /// @dev `GapPricing.normalCdf` returns exactly 0 beyond -8 sigma, so `GapPricing.call`
    /// returns exactly 0 once `d1 <= -8` — at spot 205 / 7d / 50% vol that is any strike at or
    /// above ~1.76x spot, and `createSeries` accepts any `strike > 0`. A zero or dust premium
    /// would let a taker drain a maker's entire shipped cover into a worthless series for
    /// nothing; the Aqua ledger bounds the loss to the ship amount but does not prevent it.
    /// The floor is bps of the strike notional, which is dimensionally the same thing the
    /// premium is (quote units per 1e18 options). Credit: found in the core write path, which
    /// is exposed to the identical attack through `buyOption`.
    /// @dev Takes the trade's full option `amount` rather than flooring per option and
    ///      scaling. Those are not the same number: flooring first and scaling after loses up
    ///      to a unit per option, which at size diverges by hundreds. A quote priced at exactly
    ///      a per-option floor would then sit below the core's trade-level floor and
    ///      `buyOption` would reject an order this contract had just accepted. One flooring,
    ///      one definition, no reconciliation. Mirrors the core's `buyOption` floor exactly.
    function premiumFloor(uint256 amount, uint256 strike, uint16 minPremiumBps)
        public
        pure
        returns (uint256)
    {
        return ((amount * strike) / 1e18 * minPremiumBps) / 10_000;
    }

    /// @notice Premium for one series, in quote-token units per 1e18 options.
    /// @dev Black-Scholes with r = 0 — these options live hours, so `r * T` is noise. `volWad` is
    /// the maker's own number and the only axis two makers quoting the same series differ on; a
    /// maker running both sides simply ships a higher vol on their ask order than on their bid,
    /// which is their spread. No separate spread parameter exists, deliberately.
    function premiumPerOption(uint256 seriesId, uint256 volWad) public view returns (uint256) {
        WeekendOptions.Series memory s = APP.getSeries(seriesId);
        if (block.timestamp >= s.expiry) revert SeriesExpired(s.expiry);

        (uint256 spotQuote,) = ORACLE.spot(s.underlying);
        // Oracle prices and strikes are quote units per 1e18; GapPricing is WAD-native.
        uint256 spotWad = spotQuote * QUOTE_TO_WAD;
        uint256 strikeWad = s.strike * QUOTE_TO_WAD;
        uint256 t = s.expiry - block.timestamp;

        uint256 premWad = s.kind == Kind.CALL
            ? GapPricing.call(spotWad, strikeWad, t, volWad)
            : GapPricing.put(spotWad, strikeWad, t, volWad);

        uint256 premium = premWad / QUOTE_TO_WAD;

        // Load-bearing on its own, and deliberately NOT folded into the floor check below:
        // the floor is quote-unit output, so at small size it floors to 0 and would wave a
        // dust premium straight through. `GapPricing.normalCdf` is exactly 0 beyond -8 sigma,
        // so a far enough strike prices at exactly 0 and a no-op taker would take the maker's
        // whole cover for nothing.
        if (premium == 0) revert ZeroPremium();

        return premium;
    }

    /// @inheritdoc IStaticExtruction
    /// @dev `args = abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side)`, carried in the
    /// maker's program bytes and therefore covered by the order hash. Returns `nextPC` unchanged
    /// (no jump) and consumes zero taker args.
    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    ) external view override returns (uint256, uint256, SwapRegisters memory) {
        (uint8 side, uint256 premium) = _validateAndPrice(query, args);

        SwapRegisters memory out = swap;
        _fillMissingLeg(out, side, query.isExactIn, premium);
        _enforceFloor(out, side, args);

        return (nextPC, 0, out);
    }

    /// @dev Decode, gate the direction, and price. Split out of `extruction` so the decoded
    ///      arguments die before the registers are touched — this file is compiled without
    ///      via_ir and the combined frame does not fit otherwise.
    function _validateAndPrice(SwapQuery calldata query, bytes calldata args)
        private
        view
        returns (uint8 side, uint256 premium)
    {
        uint256 seriesId;
        uint256 volWad;
        uint16 minPremiumBps;
        (seriesId, volWad, minPremiumBps, side) = abi.decode(args, (uint256, uint256, uint16, uint8));

        _gateDirection(side, query, address(APP.getSeries(seriesId).token));
        premium = premiumPerOption(seriesId, volWad);
        minPremiumBps; // consumed by `_enforceFloor`, which re-reads it from calldata
    }

    /// @dev The maker's floor, applied to the finished trade.
    ///
    ///      Ask side only, because that is where the exposure is: the maker hands out option
    ///      tokens and receives quote, so too low a price drains their shipped cover. On the
    ///      bid side the maker is paying, and a floor there would be a ceiling on their own
    ///      bid -- the taker is the one at risk and SwapVM already enforces their `minOut`
    ///      threshold after the program runs.
    ///
    ///      This matches the core rather than diverging from it, which is easy to misread the
    ///      other way: `WeekendOptions.buyOption` has no bid path to floor. The core supports
    ///      no sell-back and no maker bid, so every call there is a taker lifting a maker's ask
    ///      against shipped collateral, and its floor is ask-only by construction. The bid side
    ///      exists only out here, on the SwapVM route.
    function _enforceFloor(SwapRegisters memory out, uint8 side, bytes calldata args) private view {
        if (side != SIDE_ASK) return;
        (uint256 seriesId,, uint16 minPremiumBps,) = abi.decode(args, (uint256, uint256, uint16, uint8));
        uint256 floor = premiumFloor(out.amountOut, APP.getSeries(seriesId).strike, minPremiumBps);
        if (out.amountIn < floor) revert PremiumBelowFloor(out.amountIn, floor);
    }

    /// @dev Fills whichever amount register the taker did not specify.
    ///      Rounding always favours the maker: floor what the maker pays out, ceil what it
    ///      takes in. Split out of `extruction` to keep that frame within stack limits — this
    ///      file is compiled without via_ir.
    function _fillMissingLeg(SwapRegisters memory out, uint8 side, bool isExactIn, uint256 premium)
        private
        pure
    {
        if (side == SIDE_ASK) {
            // Taker pays quote (in), receives options (out).
            if (isExactIn) {
                if (out.amountIn == 0) revert ZeroAmount();
                out.amountOut = (out.amountIn * 1e18) / premium;
            } else {
                if (out.amountOut == 0) revert ZeroAmount();
                out.amountIn = _ceilDiv(out.amountOut * premium, 1e18);
            }
        } else {
            // Taker delivers options (in), receives quote (out).
            if (isExactIn) {
                if (out.amountIn == 0) revert ZeroAmount();
                out.amountOut = (out.amountIn * premium) / 1e18;
            } else {
                if (out.amountOut == 0) revert ZeroAmount();
                out.amountIn = _ceilDiv(out.amountOut * 1e18, premium);
            }
        }
    }

    /// @dev Refuses any fill whose direction does not match the side the maker shipped.
    function _gateDirection(uint8 side, SwapQuery calldata query, address optionToken) internal view {
        if (side == SIDE_ASK) {
            if (query.tokenIn != QUOTE || query.tokenOut != optionToken) {
                revert WrongSwapDirection(query.tokenIn, query.tokenOut);
            }
        } else if (side == SIDE_BID) {
            if (query.tokenIn != optionToken || query.tokenOut != QUOTE) {
                revert WrongSwapDirection(query.tokenIn, query.tokenOut);
            }
        } else {
            revert UnknownSide(side);
        }
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
