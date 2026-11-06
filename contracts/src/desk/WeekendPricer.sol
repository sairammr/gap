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
    error ZeroAmount();

    constructor(WeekendOptions app, IPriceOracle oracle, address quote, uint8 quoteDecimals) {
        APP = app;
        ORACLE = oracle;
        QUOTE = quote;
        QUOTE_TO_WAD = 10 ** (18 - quoteDecimals);
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

        return premWad / QUOTE_TO_WAD;
    }

    /// @inheritdoc IStaticExtruction
    /// @dev `args = abi.encode(uint256 seriesId, uint256 volWad, uint8 side)`, carried in the
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
        (uint256 seriesId, uint256 volWad, uint8 side) = abi.decode(args, (uint256, uint256, uint8));

        address optionToken = address(APP.getSeries(seriesId).token);
        _gateDirection(side, query, optionToken);

        uint256 premium = premiumPerOption(seriesId, volWad);
        if (premium == 0) revert ZeroPremium();

        SwapRegisters memory out = swap;

        // Rounding always favours the maker: floor what the maker pays out, ceil what it takes in.
        if (side == SIDE_ASK) {
            // Taker pays quote (in), receives options (out).
            if (query.isExactIn) {
                if (swap.amountIn == 0) revert ZeroAmount();
                out.amountOut = (swap.amountIn * 1e18) / premium;
            } else {
                if (swap.amountOut == 0) revert ZeroAmount();
                out.amountIn = _ceilDiv(swap.amountOut * premium, 1e18);
            }
        } else {
            // Taker delivers options (in), receives quote (out).
            if (query.isExactIn) {
                if (swap.amountIn == 0) revert ZeroAmount();
                out.amountOut = (swap.amountIn * premium) / 1e18;
            } else {
                if (swap.amountOut == 0) revert ZeroAmount();
                out.amountIn = _ceilDiv(swap.amountOut * 1e18, premium);
            }
        }

        return (nextPC, 0, out);
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
