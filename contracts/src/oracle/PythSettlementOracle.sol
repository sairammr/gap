// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IPyth, IMultiplierToken } from "../interfaces/IPyth.sol";

/// @title PythSettlementOracle
/// @notice `IPriceOracle` fed by Pyth's signed pull updates. A drop-in replacement for
///         `V4SpotOracle` — same two functions, same units (quote-token units, 6 dp, per 1e18
///         of underlying) — that exists to close the one economic hole the v4 oracle leaves
///         open.
///
/// @dev WHAT THIS FIXES. `V4SpotOracle.recordSettlement` is permissionless, one-shot, and reads
///      an instantaneous `slot0`. One atomic transaction can move the pool, record, and unwind:
///      forcing a CALL's settlement price to `<= strike` pays every in-the-money holder nothing.
///      `spot()` feeds Black-Scholes on every fill too, so entry pricing shares the root cause.
///
///      Three things here break that, and all three matter:
///
///      1. **The price is signed off-chain.** A Pyth update carries a Wormhole-signed price from
///         the aggregate of Pyth's publishers. Moving one Uniswap pool does not move it.
///      2. **Settlement is an AVERAGE over a window, not a point read.** Every update landed
///         between `expiry` and `expiry + WINDOW` is a sample, and `settlementPrice` returns
///         their mean. A single manipulated sample is diluted, not decisive, and anyone can
///         dilute it further by pushing an honest one — permissionlessly, with no reporter role.
///      3. **Wide quotes are refused.** A sample whose confidence interval exceeds `maxConfBps`
///         of its own price is rejected rather than averaged in, so a market Pyth itself is
///         unsure about cannot be used to settle.
///
/// @dev COMPATIBILITY WITH `WeekendOptions._settle`. That function treats `ok == false` as "not
///      settleable yet" and only after `SETTLEMENT_GRACE` falls back to `spot()`. If `WINDOW`
///      were >= that grace period the fallback would always fire first, and settlement would
///      silently revert to a single instantaneous read — the exact failure this contract
///      exists to remove. The constructor refuses that configuration outright.
///
/// @dev The owner can configure feeds and nothing else. It cannot set, veto, or freeze a price:
///      every sample comes from a Pyth signature, `recordSample` is permissionless, and
///      `WINDOW` is immutable so the moment a price finalises cannot be moved after the fact.
contract PythSettlementOracle is IPriceOracle, Ownable2Step {
    /// @notice Mirrors `WeekendOptions.SETTLEMENT_GRACE`. `WINDOW` must stay strictly under it.
    uint64 public constant MAX_WINDOW = 7 days;

    struct Feed {
        /// @notice Pyth price id for the underlying SHARE.
        bytes32 priceId;
        /// @notice Wrapper exposing `multiplier()`, or zero for a 1:1 token.
        address multiplierSource;
        /// @notice `spot()` only. Older than this and `spot` reports no price. 0 = no limit.
        uint64 maxStaleness;
        /// @notice Reject a sample whose `conf` exceeds this many bps of its price. 0 = no limit.
        uint16 maxConfBps;
    }

    /// @dev Running mean, kept as sum/count so a sample costs one SSTORE pair and no array.
    struct Acc {
        uint256 sum;
        uint256 count;
        uint256 lastPublish;
    }

    IPyth public immutable PYTH;
    /// @notice Seconds after expiry during which updates are accepted as settlement samples.
    uint64 public immutable WINDOW;

    mapping(address asset => Feed) public feeds;
    mapping(address asset => mapping(uint64 expiry => Acc)) internal _acc;

    event FeedSet(
        address indexed asset, bytes32 priceId, address multiplierSource, uint64 maxStaleness, uint16 maxConfBps
    );
    event Sample(address indexed asset, uint64 indexed expiry, uint256 price, uint256 publishTime);

    error NoFeed();
    error WindowTooLong();
    error OutsideWindow();
    error StaleOrDuplicate();
    error LowConfidence();
    error BadPrice();
    error RefundFailed();

    constructor(IPyth pyth_, uint64 window_) Ownable(msg.sender) {
        // A zero window would accept only updates published in the same second as expiry, which
        // is a point read with extra steps; `>= MAX_WINDOW` loses to the grace fallback. Both
        // reintroduce the single-read exposure, so both are refused here rather than documented.
        if (window_ == 0 || window_ >= MAX_WINDOW) revert WindowTooLong();
        PYTH = pyth_;
        WINDOW = window_;
    }

    // ---------------------------------------------------------------- admin

    function setFeed(address asset, bytes32 priceId, address multiplierSource, uint64 maxStaleness, uint16 maxConfBps)
        external
        onlyOwner
    {
        feeds[asset] = Feed(priceId, multiplierSource, maxStaleness, maxConfBps);
        emit FeedSet(asset, priceId, multiplierSource, maxStaleness, maxConfBps);
    }

    // ---------------------------------------------------------------- sampling

    /// @notice Push Pyth updates and record one settlement sample. Anyone may call.
    /// @dev `msg.value` must cover `PYTH.getUpdateFee`; the excess is refunded to the caller.
    ///      All state is written before the refund, and a sample strictly newer than the last
    ///      one is required, so re-entering through the refund can only ever add a further
    ///      honest sample — never replay this one.
    ///
    ///      The refund REVERTS on failure rather than being swallowed. Swallowing it strands
    ///      the ether in a contract with no sweep; a caller that cannot receive ether should
    ///      send the exact fee.
    function recordSample(address asset, uint64 expiry, bytes[] calldata updateData) external payable {
        Feed memory f = feeds[asset];
        if (f.priceId == bytes32(0)) revert NoFeed();

        uint256 fee = PYTH.getUpdateFee(updateData);
        PYTH.updatePriceFeeds{ value: fee }(updateData);

        IPyth.Price memory p = PYTH.getPriceUnsafe(f.priceId);
        // Half-open on the left, closed on the right: a price published BEFORE expiry describes
        // a market that had not yet settled, and one after the window is simply late.
        if (p.publishTime < expiry || p.publishTime > expiry + WINDOW) revert OutsideWindow();
        if (p.price <= 0) revert BadPrice();
        if (f.maxConfBps != 0 && uint256(p.conf) * 10_000 > uint256(uint64(p.price)) * f.maxConfBps) {
            revert LowConfidence();
        }

        Acc storage a = _acc[asset][expiry];
        // Strictly newer, so the same signed update cannot be replayed to weight itself.
        if (p.publishTime <= a.lastPublish) revert StaleOrDuplicate();

        uint256 px = _toTokenPrice(f, p);
        // A price that rounds to zero in quote units is not a price. Averaging it in would drag
        // the mean toward zero, which on a CALL is the same attack this contract closes.
        if (px == 0) revert BadPrice();

        a.sum += px;
        a.count += 1;
        a.lastPublish = p.publishTime;
        emit Sample(asset, expiry, px, p.publishTime);

        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{ value: msg.value - fee }("");
            if (!ok) revert RefundFailed();
        }
    }

    // ---------------------------------------------------------------- IPriceOracle

    /// @notice Latest reference price, in quote-token units. Returns `(0, …)` rather than
    ///         reverting when the asset has no feed or the feed has gone stale — `buyOption`
    ///         refuses a zero spot on its own, and `_settle`'s grace path depends on this being
    ///         a silent probe.
    function spot(address asset) external view returns (uint256 price, uint256 updatedAt) {
        Feed memory f = feeds[asset];
        if (f.priceId == bytes32(0)) return (0, 0);

        IPyth.Price memory p = PYTH.getPriceUnsafe(f.priceId);
        if (p.price <= 0) return (0, p.publishTime);
        if (f.maxStaleness != 0 && p.publishTime + f.maxStaleness < block.timestamp) return (0, p.publishTime);
        return (_toTokenPrice(f, p), p.publishTime);
    }

    /// @notice The mean of every sample recorded in the window, final only once the window has
    ///         closed. `ok == false` until then, which `_settle` reads as "not settleable yet".
    /// @dev The window must CLOSE before the average is final — reporting a running mean early
    ///      would let a holder settle on one cherry-picked sample before honest ones land.
    function settlementPrice(address asset, uint64 expiry) external view returns (uint256 price, bool ok) {
        Acc storage a = _acc[asset][expiry];
        if (a.count == 0 || block.timestamp <= expiry + WINDOW) return (0, false);
        return (a.sum / a.count, true);
    }

    /// @notice The raw accumulator, for keepers deciding whether another sample is worth pushing.
    function samples(address asset, uint64 expiry) external view returns (uint256 sum, uint256 count) {
        Acc storage a = _acc[asset][expiry];
        return (a.sum, a.count);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Pyth price (`price * 10**expo` USD per share) -> quote units per 1e18 of the token.
    function _toTokenPrice(Feed memory f, IPyth.Price memory p) internal view returns (uint256 px) {
        if (p.price <= 0) return 0;
        uint256 raw = uint256(uint64(p.price));

        int256 e = int256(p.expo) + 6; // Pyth decimals -> the quote's 6
        if (e >= 0) px = raw * (10 ** uint256(e));
        else px = raw / (10 ** uint256(-e));

        if (f.multiplierSource != address(0)) {
            px = px * IMultiplierToken(f.multiplierSource).multiplier() / 1e18;
        }
    }
}
