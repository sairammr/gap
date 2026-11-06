// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AquaApp } from "@1inch/aqua/contracts/AquaApp.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { FixedPointMathLib as F } from "solady/utils/FixedPointMathLib.sol";
import { LibString } from "solady/utils/LibString.sol";

import { OptionToken, OptionTokenFactory } from "./OptionToken.sol";
import { IGapOptionCallback } from "./interfaces/IGapOptionCallback.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { GapPricing } from "./lib/GapPricing.sol";

/// @notice CALL (writer locks underlying) or PUT (writer locks quote). Order matches
/// `GapPricing.CALL` (0) / `GapPricing.PUT` (1).
enum Kind {
    CALL,
    PUT
}

/// @title WeekendOptions
/// @notice Fully collateralized, physically-settled options on tokenized stocks, priced in one
/// quote token (USDC).
///
/// Units: underlying and option amounts are 18 decimals. `strike` and every oracle price are
/// quote-token units (6 dp USDC) per 1e18 of underlying.
contract WeekendOptions is AquaApp {
    // ---------------------------------------------------------------- types

    /// @notice A maker's option-writing strategy. Field order is load-bearing: `hashStrategy`
    /// is `keccak256(abi.encode(s))` and must equal the hash Aqua derives from the identical
    /// bytes the maker passes to `AQUA.ship`.
    ///
    /// There is deliberately no pool id or decimals here — the oracle owns pool configuration,
    /// so two makers quoting the same series differ only by `volWad`. Implied vol is the
    /// competitive axis, exactly as on a real options book.
    ///
    /// `minPremiumBps` is the maker's own floor, in bps of the strike notional. It exists
    /// because Black-Scholes genuinely prices far-OTM options at zero (Ruling 11): the maker,
    /// not the protocol, decides how little premium is worth locking their cover for.
    struct Strategy {
        address app;
        address maker;
        address underlying;
        address quote;
        uint256 volWad;
        uint16 minPremiumBps;
        // Rider D: the per-maker bound on how far out a series' expiry may be at buy time.
        // `Strategy` binds no series/strike/expiry and `createSeries` is permissionless out to
        // 400 days, so without this a maker's weekend-calibrated vol could be applied to a
        // series an attacker opens far in the future, locking the maker's cover for over a year
        // against a premium priced for a two-day tenor. Enforced in `_buyOption`.
        uint64 maxSecondsToExpiry;
        bytes32 salt;
    }

    struct Series {
        address underlying;
        uint64 expiry;
        Kind kind;
        uint256 strike;
        OptionToken token;
        uint256 totalWritten;
        uint256 poolUnderlying;
        uint256 poolCash;
        bool settled;
        uint256 settlePrice;
        uint256 supplyAtSettle;
        uint256 holderUnderlying;
        uint256 holderCash;
        uint256 writerUnderlying;
        uint256 writerCash;
        uint256 writtenAtSettle;
    }

    // ---------------------------------------------------------------- constants

    uint256 public constant SETTLEMENT_GRACE = 7 days;

    // ---------------------------------------------------------------- immutables & state

    /// @notice The single quote asset every series' PUT side locks (the USDC-equivalent).
    address public immutable quote;
    OptionTokenFactory public immutable tokenFactory;
    IPriceOracle public immutable oracle;

    /// @dev One whole unit of the quote token (1e6 for USDC). The only bridge between the
    /// protocol's quote units and `GapPricing`'s WAD.
    uint256 internal immutable quoteUnit;

    Series[] internal _series;
    mapping(bytes32 => uint256) public seriesIdOf; // key => id + 1
    mapping(uint256 => mapping(address => uint256)) public written;

    // ---------------------------------------------------------------- events

    event SeriesCreated(
        uint256 indexed seriesId, address indexed underlying, uint64 expiry, Kind kind, uint256 strike, address token
    );

    event OptionWritten(
        uint256 indexed seriesId, address indexed to, address indexed maker, uint256 amount, uint256 premium
    );

    event Exercised(uint256 indexed seriesId, address indexed holder, uint256 amount);

    event Closed(uint256 indexed seriesId, address indexed writer, uint256 amount);

    event Settled(uint256 indexed seriesId, uint256 price, uint256 holderUnderlying, uint256 holderCash);

    event Redeemed(uint256 indexed seriesId, address indexed holder, uint256 amount, uint256 outU, uint256 outC);

    event WriterClaimed(uint256 indexed seriesId, address indexed writer, uint256 outU, uint256 outC);

    // ---------------------------------------------------------------- errors

    error BadSeries();
    error Expired();
    error NotExpired();
    error AlreadySettled();
    error BadAmount();
    error NotThisApp();
    error PremiumTooHigh();
    error InsufficientMakerCollateral();
    error StrategyMismatch();
    error NoPrice();
    error ZeroPremium();
    error PremiumBelowFloor();
    error NotExercisable();
    error TransferFailed();
    error CloseAfterExercise();
    error ShortPull();
    error OracleNotReady();
    error TenorTooLong();

    constructor(address quote_, OptionTokenFactory factory_, IAqua aqua_, IPriceOracle oracle_) AquaApp(aqua_) {
        quote = quote_;
        tokenFactory = factory_;
        oracle = oracle_;
        quoteUnit = 10 ** IERC20Metadata(quote_).decimals();
        tokenFactory.bind(address(this));
    }

    // ---------------------------------------------------------------- series registry

    /// @notice Permissionless. Opens the series for this (underlying, expiry, kind, strike) key,
    /// or returns the existing id if one was already opened.
    function createSeries(address underlying, uint64 expiry, Kind kind, uint256 strike)
        external
        returns (uint256 id)
    {
        // Rider A: the source protocol gated underlyings behind an owner allowlist; this port
        // deliberately has no allowlist (no admin key in a contract whose claim is that nothing
        // can be seized), but a series whose underlying IS the quote token is incoherent on its
        // own terms (the writer locks and the exerciser pays the SAME asset) and is rejected.
        if (
            expiry <= block.timestamp || expiry > block.timestamp + 400 days || strike == 0 || underlying == quote
        ) revert BadSeries();

        bytes32 key = keccak256(abi.encode(underlying, expiry, kind, strike));
        uint256 existing = seriesIdOf[key];
        if (existing != 0) return existing - 1;

        id = _series.length;
        string memory tag = kind == Kind.CALL ? "UP" : "FLOOR";
        string memory idStr = LibString.toString(id);
        OptionToken token =
            tokenFactory.deploy(string.concat("Weekend ", tag, " #", idStr), string.concat(tag, "-", idStr), id);

        Series storage s = _series.push();
        s.underlying = underlying;
        s.expiry = expiry;
        s.kind = kind;
        s.strike = strike;
        s.token = token;

        seriesIdOf[key] = id + 1;
        emit SeriesCreated(id, underlying, expiry, kind, strike, address(token));
    }

    function seriesCount() external view returns (uint256) {
        return _series.length;
    }

    function getSeries(uint256 id) external view returns (Series memory) {
        return _series[id];
    }

    /// @notice Token and amount a writer must lock for `amount` options.
    /// @dev No Ceil in the settlement block (spec §10); this is one of the two Ceils in the
    /// protocol outside it — the writer's obligation rounds up against them. (The other is
    /// `exercise`'s CALL `pay`, which rounds up against the exerciser.)
    function collateralFor(uint256 id, uint256 amount) public view returns (address token, uint256 need) {
        Series storage s = _series[id];
        if (s.kind == Kind.CALL) return (s.underlying, amount);
        return (quote, F.fullMulDivUp(amount, s.strike, 1e18));
    }

    // ---------------------------------------------------------------- quoting

    /// @notice Strategy hash == the raw bytes Aqua hashes in `ship`.
    function hashStrategy(Strategy calldata s) public pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    /// @notice Black-Scholes premium for `amount` options of `seriesId`, in quote-token units.
    /// @dev `GapPricing` is WAD-native, so the oracle spot and the series strike (both quote
    /// units) are widened to WAD on the way in and the result is narrowed back on the way out.
    /// A `view` probe, so `secondsToExpiry` floors at 0 instead of underflowing once the series
    /// has expired; `buyOption` separately refuses an expired series.
    function quotePremium(Strategy calldata s, uint256 seriesId, uint256 amount) public view returns (uint256) {
        Series storage ser = _series[seriesId];
        (uint256 spotQuote,) = oracle.spot(ser.underlying);
        // A silent oracle is UNPRICEABLE, not free. Without this, a zero spot would quote 0 for
        // every call (fine-looking, wrong) and `strike * amount` for every put (confidently
        // absurd). `buyOption` refuses the same condition outright with `NoPrice()`.
        if (spotQuote == 0) return 0;

        uint256 spotWad = _toWad(spotQuote);
        uint256 strikeWad = _toWad(ser.strike);
        uint256 tte = ser.expiry > block.timestamp ? ser.expiry - block.timestamp : 0;

        uint256 premWad = ser.kind == Kind.CALL
            ? GapPricing.call(spotWad, strikeWad, tte, s.volWad)
            : GapPricing.put(spotWad, strikeWad, tte, s.volWad);

        return _fromWad(F.mulWad(premWad, amount));
    }

    /// @notice How much `token` collateral a maker can ACTUALLY honour under this strategy.
    /// @dev The `min` is the whole point of this function.
    ///
    /// `AQUA.ship` only writes an accounting entry. No ERC-20 moves at ship time — the tokens
    /// leave the maker's own wallet later, when this app calls `AQUA.pull` inside `buyOption`.
    /// So the two numbers below are independent and can disagree: a maker can be fully
    /// committed on Aqua's books and broke in their wallet. Solvency is therefore the MINIMUM
    /// of the promise and the means, never either one alone.
    /// @return committed Collateral committed to this strategy on Aqua's books.
    /// @return wallet The maker's actual `token` wallet balance.
    /// @return backable min(committed, wallet) — what a buy can really pull.
    function makerCapacity(Strategy calldata s, address token)
        public
        view
        returns (uint256 committed, uint256 wallet, uint256 backable)
    {
        (uint248 raw,) = AQUA.rawBalances(s.maker, address(this), hashStrategy(s), token);
        committed = raw;
        wallet = IERC20Metadata(token).balanceOf(s.maker);
        backable = committed < wallet ? committed : wallet;
    }

    // ---------------------------------------------------------------- write path

    /// @dev `buyOption`'s arguments, packed to keep its stack shallow (no via_ir in this build).
    struct BuyArgs {
        uint256 seriesId;
        uint256 amount;
        uint256 maxPremium;
        address to;
    }

    /// @notice Write `amount` options of `seriesId` against the maker's shipped cover.
    /// @dev The caller must implement `IGapOptionCallback`: the premium is collected by calling
    /// back into `msg.sender`, which pushes it into the maker's Aqua balance (see `WeekendTaker`).
    ///
    /// Operational note for makers: `AQUA.push` only lands on a token that is part of the
    /// shipped strategy, so a CALL maker must include the quote token in `ship` (an amount of 0
    /// is fine) or the premium leg reverts `PushToNonActiveStrategyPrevented`.
    function buyOption(
        Strategy calldata s,
        uint256 seriesId,
        uint256 amount,
        uint256 maxPremium,
        address to,
        bytes calldata takerData
    ) external nonReentrantStrategy(s.maker, hashStrategy(s)) returns (uint256 premium) {
        return _buyOption(s, BuyArgs(seriesId, amount, maxPremium, to), takerData);
    }

    function _buyOption(Strategy calldata s, BuyArgs memory a, bytes calldata takerData)
        internal
        returns (uint256 premium)
    {
        if (s.app != address(this)) revert NotThisApp();
        if (a.amount == 0) revert BadAmount();

        if (a.seriesId >= _series.length) revert BadSeries();
        Series storage ser = _series[a.seriesId];
        if (s.underlying != ser.underlying || s.quote != quote) revert StrategyMismatch();
        if (block.timestamp >= ser.expiry) revert Expired();
        // Rider D: bounds the tenor a maker's shipped vol can be applied to. Safe to subtract
        // unchecked — the `Expired` check above already guarantees `ser.expiry > block.timestamp`.
        if (ser.expiry - block.timestamp > s.maxSecondsToExpiry) revert TenorTooLong();

        // `oracle.spot` answers (0, 0) for an unconfigured or uninitialised pool rather than
        // reverting (Task 3, for the settlement grace path). Here that silence would price
        // every call at zero and hand out free options against the maker's cover, so the write
        // path refuses it. `quotePremium` stays a non-reverting probe.
        (uint256 spotQuote,) = oracle.spot(ser.underlying);
        if (spotQuote == 0) revert NoPrice();

        premium = quotePremium(s, a.seriesId, a.amount);
        // Maker-side floors, BEFORE the taker's ceiling. `GapPricing.normalCdf` returns exactly
        // 0 beyond -8 sigma, so a far-OTM option genuinely prices to 0 — and `_safeCheckAquaPush`
        // is a `>=`, so a premium of 0 is satisfied by a taker that pushes nothing at all. Left
        // open, that lets anyone drain a maker's whole shipped cover into a worthless series for
        // gas. The strategy bytes to do it are public: `Aqua.ship` emits them in `Shipped`.
        if (premium == 0) revert ZeroPremium();
        if (premium < _premiumFloor(s.minPremiumBps, ser.strike, a.amount)) revert PremiumBelowFloor();
        if (premium > a.maxPremium) revert PremiumTooHigh();

        (address token, uint256 need) = collateralFor(a.seriesId, a.amount);
        // Solvency BEFORE the pull: a maker whose wallet has been drained since shipping must
        // fail here, legibly, instead of deep inside Aqua with `ERC20InsufficientBalance`.
        (,, uint256 backable) = makerCapacity(s, token);
        if (backable < need) revert InsufficientMakerCollateral();

        // Effects.
        if (ser.kind == Kind.CALL) ser.poolUnderlying += need;
        else ser.poolCash += need;
        ser.totalWritten += a.amount;
        written[a.seriesId][s.maker] += a.amount;

        // Interactions: take the cover, mint the option, collect the premium.
        bytes32 hash = hashStrategy(s);
        // Rider B: `AQUA.pull` moves `safeTransferFrom(maker, this, need)` but never measures
        // what actually arrived. A fee-on-transfer or rebasing underlying would otherwise
        // under-collateralize the series silently (the pool leg above is already credited with
        // the FULL `need`). Measuring the real balance delta and reverting on a shortfall is
        // what makes that pool credit honest.
        uint256 balBefore = IERC20Metadata(token).balanceOf(address(this));
        AQUA.pull(s.maker, hash, token, need, address(this));
        if (IERC20Metadata(token).balanceOf(address(this)) - balBefore < need) revert ShortPull();
        ser.token.mint(a.to, a.amount);
        _collectPremium(s.maker, hash, premium, a.to, takerData);

        emit OptionWritten(a.seriesId, a.to, s.maker, a.amount, premium);
    }

    /// @dev Invoke the taker callback to push the premium, then verify the push landed.
    /// The snapshot is taken AFTER `AQUA.pull`: on a PUT the pull drains the very same quote
    /// balance, so a snapshot taken earlier would demand the taker refund the cover too.
    function _collectPremium(address maker, bytes32 hash, uint256 premium, address to, bytes calldata takerData)
        internal
    {
        (uint256 quoteBalBeforePush,) = AQUA.rawBalances(maker, address(this), hash, quote);
        IGapOptionCallback(msg.sender).gapOptionCallback(to, quote, premium, takerData);
        _safeCheckAquaPush(maker, hash, quote, quoteBalBeforePush + premium);
    }

    /// @notice The maker's minimum acceptable premium for `amount` options, in quote units.
    /// @dev Taken off the STRIKE NOTIONAL (`amount * strike / 1e18`), not off the collateral:
    /// collateral is underlying-denominated for a CALL and quote-denominated for a PUT, so bps
    /// of it would mean two different things. The strike notional is quote-denominated for both,
    /// which is what the premium is too. Both steps floor — no Ceil in the settlement block.
    function _premiumFloor(uint16 minPremiumBps, uint256 strike, uint256 amount) internal pure returns (uint256) {
        return F.fullMulDiv(F.fullMulDiv(amount, strike, 1e18), minPremiumBps, 10_000);
    }

    /// @dev quote units -> WAD.
    function _toWad(uint256 x) internal view returns (uint256) {
        return F.fullMulDiv(x, 1e18, quoteUnit);
    }

    /// @dev WAD -> quote units.
    function _fromWad(uint256 x) internal view returns (uint256) {
        return F.fullMulDiv(x, quoteUnit, 1e18);
    }

    // ---------------------------------------------------------------- exercise

    /// @notice American physical exercise: pay the strike and take the stock (CALL), or deliver
    /// the stock and take the strike (PUT). Any holder, any time strictly before expiry, any
    /// amount up to their balance.
    /// @dev Reads no oracle. Every other settlement route in this protocol (quoting, settlement)
    /// depends on a price; this one deliberately does not, because the whole point of a
    /// physically-settled option is that the holder doesn't need a published price — they simply
    /// name it themselves by paying the strike. That is what keeps this route open when the
    /// underlying market, and so the oracle, is shut.
    ///
    /// Effects (burn, pool bookkeeping) happen before either ERC-20 leg moves.
    function exercise(uint256 id, uint256 amount) external {
        if (id >= _series.length) revert BadSeries();
        Series storage s = _series[id];
        // Unreachable while `Kind` has only CALL/PUT, kept for parity with the ported function
        // and as a guard if a non-exercisable kind is ever added.
        if (s.kind != Kind.CALL && s.kind != Kind.PUT) revert NotExercisable();
        if (block.timestamp >= s.expiry) revert Expired();
        if (amount == 0) revert BadAmount();

        // Effects.
        s.token.burn(msg.sender, amount);
        if (s.kind == Kind.CALL) {
            // Rounds UP, against the exerciser — matches `collateralFor`'s only-Ceil direction.
            uint256 pay = F.fullMulDivUp(amount, s.strike, 1e18);
            s.poolCash += pay;
            s.poolUnderlying -= amount;

            // Interactions.
            require(IERC20Metadata(quote).transferFrom(msg.sender, address(this), pay), TransferFailed());
            require(IERC20Metadata(s.underlying).transfer(msg.sender, amount), TransferFailed());
        } else {
            uint256 get = F.fullMulDiv(amount, s.strike, 1e18); // floors
            s.poolUnderlying += amount;
            s.poolCash -= get;

            // Interactions. Mirrors Rider B's `ShortPull` guard in `_buyOption`: for a PUT, the
            // underlying reaches the contract ONLY here (never through `AQUA.pull`), and
            // `poolUnderlying` above is already credited the full `amount` -- measuring what
            // actually arrived is what keeps that credit honest against a fee-on-transfer token.
            uint256 balBefore = IERC20Metadata(s.underlying).balanceOf(address(this));
            require(IERC20Metadata(s.underlying).transferFrom(msg.sender, address(this), amount), TransferFailed());
            if (IERC20Metadata(s.underlying).balanceOf(address(this)) - balBefore < amount) revert ShortPull();
            require(IERC20Metadata(quote).transfer(msg.sender, get), TransferFailed());
        }

        emit Exercised(id, msg.sender, amount);
    }

    // ---------------------------------------------------------------- close

    /// @notice Pre-expiry writer unwind: burn `amount` of the caller's written position and
    /// release their pro-rata share of both pool legs, directly to their wallet.
    /// @dev Pro-rata is computed on the PRE-decrement `totalWritten` — the ordering below is
    /// load-bearing, matching the source protocol's `close`. Effects (burn, bookkeeping) happen
    /// strictly before either ERC-20 leg moves.
    ///
    /// Proceeds go straight to `msg.sender`'s wallet, never through `AQUA.push`: this port has
    /// no `freeBalance` ledger, and `push` reverts `PushToNonActiveStrategyPrevented` once a
    /// maker has docked their strategy, which would otherwise strand a writer's own claim behind
    /// their own revocation.
    ///
    /// RULING 13 — knowing divergence from the source protocol, not in the original brief.
    /// `close` pays pro-rata across BOTH legs on the pre-decrement `totalWritten`. A writer who
    /// enters a CALL series AFTER holders have exercised buys into a pool that already holds
    /// cash banked at the strike, and this payout rule lets them extract that cash immediately —
    /// profitable at every spot below the strike, and zero-sum against the writers who were
    /// already there (worked example: W=10 written, X=4 exercised, strike 205, an attacker
    /// writes A=10 and closes it for outU = (W-X+A)*A/(W+A) = 8e18 and outC =
    /// X*K*A/(W+A) = 410e6 against a cost of 10*spot — a profit at spot 201, for instance).
    /// So `close` additionally reverts once the OPPOSITE leg is non-empty: `poolCash` on a CALL,
    /// `poolUnderlying` on a PUT. Only `exercise` credits that opposite leg pre-expiry, and
    /// `settle` deliberately never touches the pools, so a single exercise anywhere in a
    /// series's life shuts this path for the rest of its life.
    ///
    /// The trade this accepts: a holder of as little as 1 wei of options can exercise (a dust
    /// strike still rounds up to one quote unit, ~1e-6 USDC, under `fullMulDivUp`) and freeze
    /// `close` for every writer in the series until expiry — a bounded LIVENESS hole in exchange
    /// for closing a VALUE hole. That is acceptable because the freeze itself extracts nothing,
    /// and every writer is still made whole at settlement (Task 7/8) regardless.
    function close(uint256 id, uint256 amount) external {
        if (id >= _series.length) revert BadSeries();
        Series storage s = _series[id];
        if (block.timestamp >= s.expiry) revert Expired();
        if (amount == 0 || written[id][msg.sender] < amount) revert BadAmount();
        if (s.kind == Kind.CALL ? s.poolCash != 0 : s.poolUnderlying != 0) revert CloseAfterExercise();

        // Effects.
        s.token.burn(msg.sender, amount);

        uint256 totalWritten = s.totalWritten; // pre-decrement snapshot — order is load-bearing
        uint256 outU = F.fullMulDiv(s.poolUnderlying, amount, totalWritten); // floors
        uint256 outC = F.fullMulDiv(s.poolCash, amount, totalWritten); // floors

        written[id][msg.sender] -= amount;
        s.totalWritten = totalWritten - amount;
        s.poolUnderlying -= outU;
        s.poolCash -= outC;

        // Interactions.
        require(IERC20Metadata(s.underlying).transfer(msg.sender, outU), TransferFailed());
        require(IERC20Metadata(quote).transfer(msg.sender, outC), TransferFailed());

        emit Closed(id, msg.sender, amount);
    }

    // ---------------------------------------------------------------- settlement

    /// @dev Staged settlement outputs, computed in memory before `_settle`'s storage writes.
    /// Keeping this off `_settle`'s own stack is what keeps six-plus local writes from tripping
    /// stack-too-deep under this build's `via_ir = false`.
    struct SettleResult {
        uint256 price;
        uint256 supply;
        uint256 holderUnderlying;
        uint256 holderCash;
    }

    /// @notice After expiry, fix the holder/writer payout split for `id` using the oracle's
    /// time-weighted settlement price, falling back to spot after a grace window.
    function settle(uint256 id) external {
        _settle(id);
    }

    /// @dev Internal and separately callable so a lazy `redeem`/`claim` (Task 8) can settle a
    /// series on first touch instead of requiring a separate `settle` call first.
    ///
    /// Three behaviours below look like bugs and are not — all three are ported verbatim from
    /// the source protocol (spec §10) and are load-bearing for Task 8:
    /// 1. `poolUnderlying`/`poolCash` are never zeroed or decremented here. They go stale the
    ///    instant `settled` flips true; every payout runs off the six snapshot fields instead.
    /// 2. The `p > 0` gate means a GENUINE settlement price of exactly 0 still pays PUT holders
    ///    nothing, even though intrinsic would then be the full strike — zero is overloaded here
    ///    as "no price", not "worthless underlying".
    /// 3. The two `min` caps below are applied once, at settle time, not at payout, and they
    ///    truncate silently.
    function _settle(uint256 id) internal {
        if (id >= _series.length) revert BadSeries();
        Series storage s = _series[id];
        if (block.timestamp < s.expiry) revert NotExpired();
        if (s.settled) revert AlreadySettled();

        SettleResult memory r = _resolveSettlement(s);

        // Caps applied at settle, not at payout (behaviour 3 above): a pool partially drained by
        // exercises before expiry never pays out more than it actually holds.
        uint256 hU = r.holderUnderlying > s.poolUnderlying ? s.poolUnderlying : r.holderUnderlying;
        uint256 hC = r.holderCash > s.poolCash ? s.poolCash : r.holderCash;

        s.settled = true;
        s.settlePrice = r.price;
        s.supplyAtSettle = r.supply;
        s.holderUnderlying = hU;
        s.holderCash = hC;
        // Exact subtractions (not a second `mulDiv`) against the STILL-STALE pool fields
        // (behaviour 1 above) — this is spec §10's binding arithmetic, not an approximation.
        s.writerUnderlying = s.poolUnderlying - hU;
        s.writerCash = s.poolCash - hC;
        s.writtenAtSettle = s.totalWritten;

        emit Settled(id, r.price, hU, hC);
    }

    /// @dev Oracle sequence (spec §10):
    /// 1. `settlementPrice(underlying, expiry)` → if `ok`, that price wins outright.
    /// 2. `!ok` and still inside the grace window → the series simply isn't settleable yet.
    /// 3. `!ok` and past grace → fall back to `spot`, but ONLY if it was published at or after
    ///    expiry; a spot published before expiry is stale and is rejected (`p` becomes 0, not
    ///    the stale number).
    ///
    /// Then computes the raw (uncapped) holder shares. Every formula here floors
    /// (`F.fullMulDiv`, never `fullMulDivUp`) — there is no Ceil anywhere in the settlement block.
    function _resolveSettlement(Series storage s) internal view returns (SettleResult memory r) {
        (uint256 p, bool ok) = oracle.settlementPrice(s.underlying, s.expiry);
        if (!ok) {
            if (block.timestamp < s.expiry + SETTLEMENT_GRACE) revert OracleNotReady();
            (uint256 sp, uint256 updatedAt) = oracle.spot(s.underlying);
            p = updatedAt >= s.expiry ? sp : 0;
        }

        uint256 supply = s.token.totalSupply();
        uint256 hU;
        uint256 hC;
        // `p > 0` gates both branches (behaviour 2 on `_settle`): see its natspec.
        if (p > 0) {
            if (s.kind == Kind.CALL) {
                if (p > s.strike) hU = F.fullMulDiv(supply, p - s.strike, p);
            } else {
                hC = F.fullMulDiv(supply, s.strike > p ? s.strike - p : 0, 1e18);
            }
        }

        r.price = p;
        r.supply = supply;
        r.holderUnderlying = hU;
        r.holderCash = hC;
    }

    // ---------------------------------------------------------------- payouts

    /// @notice Redeem `amount` of the caller's option tokens for their pro-rata share of the
    /// post-expiry holder payout. Lazy-settles the series on first touch if nobody called
    /// `settle` yet.
    function redeem(uint256 id, uint256 amount) external returns (uint256 outU, uint256 outC) {
        return _redeem(id, msg.sender, amount);
    }

    /// @notice Permissionless: pays `holder`'s FULL balance, never the caller's. Lets a keeper
    /// redeem on behalf of holders who never click anything.
    function redeemFor(uint256 id, address holder) external returns (uint256 outU, uint256 outC) {
        uint256 bal = _series[id].token.balanceOf(holder);
        if (bal == 0) return (0, 0);
        return _redeem(id, holder, bal);
    }

    /// @notice One-shot claim of the caller's ENTIRE written position. A second call is a no-op.
    function claim(uint256 id) external returns (uint256 outU, uint256 outC) {
        return _claim(id, msg.sender);
    }

    /// @notice Permissionless: always credits `writer`, never the caller.
    function claimFor(uint256 id, address writer) external returns (uint256 outU, uint256 outC) {
        return _claim(id, writer);
    }

    /// @dev Lazy-settles, burns `amount` from `holder`, then pays their pro-rata share of the
    /// SNAPSHOT holder pools (`holderUnderlying`/`holderCash`), never the live pools. The
    /// denominator is `supplyAtSettle`, frozen at the first settle touch — that is what keeps
    /// repeated partial redemptions pro-rata-stable against each other (spec §10).
    ///
    /// `supplyAtSettle == 0` is guarded explicitly rather than divided through: it can only arise
    /// when every option was exercised before anyone settled, in which case no holder balance can
    /// be nonzero either, but the guard still keeps a literal `redeem(id, 0)` call in that state
    /// from computing a 0/0 division.
    ///
    /// Pays by direct ERC-20 transfer, never `AQUA.push` (spec §11): `push` reverts
    /// `PushToNonActiveStrategyPrevented` on a docked strategy, which would strand a holder's
    /// payout behind someone else's revoked strategy. Effects (the burn) happen before transfers.
    function _redeem(uint256 id, address holder, uint256 amount) internal returns (uint256 outU, uint256 outC) {
        Series storage s = _series[id];
        if (!s.settled) _settle(id);

        s.token.burn(holder, amount);
        if (s.supplyAtSettle == 0) return (0, 0);

        outU = F.fullMulDiv(s.holderUnderlying, amount, s.supplyAtSettle);
        outC = F.fullMulDiv(s.holderCash, amount, s.supplyAtSettle);

        if (outU > 0) require(IERC20Metadata(s.underlying).transfer(holder, outU), TransferFailed());
        if (outC > 0) require(IERC20Metadata(quote).transfer(holder, outC), TransferFailed());

        emit Redeemed(id, holder, amount, outU, outC);
    }

    /// @dev Lazy-settles, then pays `writer`'s ENTIRE written position, one-shot: `w` is cached
    /// first and `written[id][writer]` is zeroed BEFORE the payout is computed, so a second call
    /// reads `w == 0` and returns `(0, 0)` immediately — there is no partial claim.
    ///
    /// The denominator `writtenAtSettle` cannot be zero whenever `w > 0`: it is `totalWritten` at
    /// the moment of settlement, and a nonzero written position can only ever shrink between then
    /// and now (via `close`, which only runs pre-expiry), never grow from zero.
    ///
    /// Pays by direct ERC-20 transfer to the writer's own wallet, never `AQUA.push` (spec §11),
    /// for the same reason as `_redeem` above.
    function _claim(uint256 id, address writer) internal returns (uint256 outU, uint256 outC) {
        Series storage s = _series[id];
        if (!s.settled) _settle(id);

        uint256 w = written[id][writer];
        if (w == 0) return (0, 0);
        written[id][writer] = 0;

        outU = F.fullMulDiv(s.writerUnderlying, w, s.writtenAtSettle);
        outC = F.fullMulDiv(s.writerCash, w, s.writtenAtSettle);

        if (outU > 0) require(IERC20Metadata(s.underlying).transfer(writer, outU), TransferFailed());
        if (outC > 0) require(IERC20Metadata(quote).transfer(writer, outC), TransferFailed());

        emit WriterClaimed(id, writer, outU, outC);
    }
}
