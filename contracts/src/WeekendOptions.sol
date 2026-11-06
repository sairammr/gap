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
/// quote token (USDC). This file holds the series registry; write/exercise/close/settlement/
/// payout/quoting surfaces are added by later tasks on top of the same contract.
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
        if (expiry <= block.timestamp || expiry > block.timestamp + 400 days || strike == 0) revert BadSeries();

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
    /// @dev The only Ceil in the protocol: the writer's obligation rounds up against them.
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
        AQUA.pull(s.maker, hash, token, need, address(this));
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
    /// which is what the premium is too. Both steps floor — `collateralFor` stays the only Ceil.
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

            // Interactions.
            require(IERC20Metadata(s.underlying).transferFrom(msg.sender, address(this), amount), TransferFailed());
            require(IERC20Metadata(quote).transfer(msg.sender, get), TransferFailed());
        }

        emit Exercised(id, msg.sender, amount);
    }
}
