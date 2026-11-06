// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AquaApp} from "@1inch/aqua/contracts/AquaApp.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";
import {IStateView} from "./interfaces/IStateView.sol";
import {IGapOptionCallback} from "./interfaces/IGapOptionCallback.sol";
import {UniV4Spot} from "./lib/UniV4Spot.sol";
import {GapPricing} from "./lib/GapPricing.sol";

/// @title GapOptionsApp
/// @notice Aqua app for Gap options. Skeleton: strategy struct, hashing, and
///         app-binding validation. Trading/settlement bodies land in later tasks.
contract GapOptionsApp is AquaApp, ERC1155 {
    /// @notice Uniswap v4 StateView lens used for on-chain pricing (Task 5).
    IStateView public immutable STATE_VIEW;

    /// @notice A maker's option-writing strategy. Field order is load-bearing:
    ///         `hashStrategy` depends on it and must match the bytes the maker
    ///         `abi.encode`s when calling `AQUA.ship`.
    struct Strategy {
        address app;
        address maker;
        address underlying;
        address quote;
        bytes32 poolId;
        bool underlyingIsCurrency0;
        uint8 underlyingDecimals;
        uint8 quoteDecimals;
        uint256 volWad;
        bytes32 salt;
    }

    /// @notice An option position minted on buy. Field order is load-bearing:
    ///         Task 7 (settle) reads these positionally.
    struct Position {
        bytes32 strategyHash;
        address maker;
        address underlying;
        address quote;
        uint8 kind;
        uint256 strike;
        uint256 cap;
        uint64 expiry;
        uint256 size;
        bool settled;
        uint256 capBacking;
    }

    /// @notice positionId => Position record.
    mapping(uint256 => Position) public positions;

    /// @notice Monotonic nonce mixed into positionId derivation.
    uint256 public optionNonce;

    /// @notice Number of spot reads averaged at settlement. In a single tx no time
    ///         passes, so every `UniV4Spot.spotWad` read is identical and the average
    ///         equals one read; this is a deliberate hook for a future multi-block
    ///         observation window. Averaging across a real settle window (TWAP-like,
    ///         manipulation resistance) is the UI/keeper's job, not this in-tx loop.
    uint256 internal constant SAMPLES = 3;

    /// @notice Thrown when a strategy is not bound to this app contract.
    error NotThisApp();
    /// @notice Thrown when the quoted premium exceeds the taker's max.
    error PremiumTooHigh();
    /// @notice Thrown when the maker's Aqua collateral is below capCollateral.
    error InsufficientMakerCollateral();
    /// @notice Thrown when buying an already-expired option.
    error OptionExpired();
    /// @notice Thrown when settling before the option's expiry.
    error NotExpired();
    /// @notice Thrown when settling an already-settled position.
    error AlreadySettled();
    /// @notice Thrown when the supplied strategy does not hash to the position's record.
    error StrategyMismatch();
    /// @notice Safety invariant: payout must never exceed the held backing. Should never trip.
    error PayoutExceedsBacking();

    /// @notice Emitted when a taker buys an option and the position is minted.
    event OptionBought(
        uint256 indexed positionId,
        address indexed to,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size,
        uint256 premium
    );

    /// @notice Emitted when a position is settled: holder paid `payout`, maker returned `remainder`.
    event OptionSettled(
        uint256 indexed positionId,
        address indexed holder,
        uint256 spotWad,
        uint256 payout,
        uint256 remainder
    );

    constructor(IAqua aqua, IStateView stateView) AquaApp(aqua) ERC1155("") {
        STATE_VIEW = stateView;
    }

    /// @dev Option economic terms, packed to keep `buyOption`'s stack shallow
    ///      (the external signature keeps them flat for Tasks 5/7).
    struct OptionTerms {
        uint8 kind;
        uint256 strike;
        uint256 cap;
        uint64 expiry;
        uint256 size;
        uint256 maxPremium;
        address to;
    }

    /// @notice Buy a cash-settled (USDC) capped option against a maker's shipped
    ///         USDC collateral. The taker pays the premium in the callback.
    /// @dev Premium is priced via Black-Scholes off the v4 spot (see `quotePremium`).
    function buyOption(
        Strategy calldata s,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size,
        uint256 maxPremium,
        address to,
        bytes calldata takerData
    ) external nonReentrantStrategy(s.maker, hashStrategy(s)) returns (uint256 positionId) {
        OptionTerms memory t = OptionTerms({
            kind: kind,
            strike: strike,
            cap: cap,
            expiry: expiry,
            size: size,
            maxPremium: maxPremium,
            to: to
        });
        return _buyOption(s, t, takerData);
    }

    function _buyOption(Strategy calldata s, OptionTerms memory t, bytes calldata takerData)
        internal
        returns (uint256 positionId)
    {
        _validateStrategy(s);
        require(t.expiry > block.timestamp, OptionExpired());

        bytes32 hash = hashStrategy(s);

        uint256 capCollateral = capBacking(t.cap, t.size);
        // Premium is priced via Black-Scholes off the v4 spot (quote units, e.g. 6dp USDC).
        uint256 premium = quotePremium(s, t.kind, t.strike, t.cap, t.expiry, t.size);
        require(premium <= t.maxPremium, PremiumTooHigh());

        // Pull the collateral into the app (with a legible solvency pre-check).
        _pullCollateral(s.maker, hash, s.quote, capCollateral);

        // Mint the position to the buyer and store its record.
        positionId = uint256(keccak256(abi.encode(hash, t.kind, t.strike, t.cap, t.expiry, t.to, optionNonce++)));
        _mintPosition(s, positionId, t, capCollateral);

        // Taker pushes the premium into the maker's Aqua balance; verify it.
        _collectPremium(s.maker, hash, s.quote, premium, t.to, takerData);

        emit OptionBought(positionId, t.to, t.kind, t.strike, t.cap, t.expiry, t.size, premium);
    }

    /// @dev Mint the ERC-1155 position and persist its record.
    function _mintPosition(Strategy calldata s, uint256 positionId, OptionTerms memory t, uint256 capCollateral)
        internal
    {
        _mint(t.to, positionId, t.size, "");
        positions[positionId] = Position({
            strategyHash: hashStrategy(s),
            maker: s.maker,
            underlying: s.underlying,
            quote: s.quote,
            kind: t.kind,
            strike: t.strike,
            cap: t.cap,
            expiry: t.expiry,
            size: t.size,
            settled: false,
            capBacking: capCollateral
        });
    }

    /// @dev Invoke the taker callback to push the premium, then verify the push.
    function _collectPremium(
        address maker,
        bytes32 hash,
        address quote,
        uint256 premium,
        address to,
        bytes calldata takerData
    ) internal {
        (uint256 quoteBalBeforePush,) = AQUA.rawBalances(maker, address(this), hash, quote);
        IGapOptionCallback(msg.sender).gapOptionCallback(to, quote, premium, takerData);
        _safeCheckAquaPush(maker, hash, quote, quoteBalBeforePush + premium);
    }

    /// @dev Legible solvency pre-check + pull of `amount` collateral into this app.
    ///      The require avoids the raw uint248 underflow panic inside `AQUA.pull`.
    function _pullCollateral(address maker, bytes32 hash, address quote, uint256 amount) internal {
        (uint256 bal,) = AQUA.rawBalances(maker, address(this), hash, quote);
        require(bal >= amount, InsufficientMakerCollateral());
        AQUA.pull(maker, hash, quote, amount, address(this));
    }

    /// @notice Strategy hash == the raw bytes Aqua hashes in `ship`.
    function hashStrategy(Strategy calldata s) public pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    /// @notice Black-Scholes premium for one option, denominated in the quote
    ///         token's own units (e.g. 6dp USDC).
    /// @dev Spot is read from the v4 pool via `STATE_VIEW` and normalised to WAD
    ///      quote-per-underlying. The WAD premium is scaled by `size` then
    ///      converted WAD -> `s.quoteDecimals`. This is a `public view` probe, so
    ///      `secondsToExpiry` floors to 0 (never underflows) when `expiry` has
    ///      passed; `buyOption` separately guards `expiry > block.timestamp`.
    /// @param s The maker strategy (supplies pool id, decimals, orientation, vol).
    /// @param kind CALL (0) or PUT (1).
    /// @param strike Strike price, WAD.
    /// @param cap Maximum payoff per unit, WAD.
    /// @param expiry Expiry timestamp (seconds).
    /// @param size Option size, WAD.
    /// @return premiumQuoteUnits Premium in quote-token units.
    function quotePremium(
        Strategy calldata s,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size
    ) public view returns (uint256 premiumQuoteUnits) {
        uint256 spotWad = UniV4Spot.spotWad(
            STATE_VIEW, s.poolId, s.underlyingDecimals, s.quoteDecimals, s.underlyingIsCurrency0
        );
        uint256 secondsToExpiry = expiry > block.timestamp ? expiry - block.timestamp : 0;
        uint256 premWad = GapPricing.premium(kind, spotWad, strike, cap, secondsToExpiry, s.volWad);
        // Apply size (WAD), then convert WAD -> quote-token units.
        uint256 premWadSized = F.mulWad(premWad, size);
        premiumQuoteUnits = F.mulDiv(premWadSized, 10 ** s.quoteDecimals, 1e18);
    }

    /// @notice Collateral (quote-token units) a position of these terms locks from the maker.
    /// @dev capBacking = cap * size / 1e30 (WAD * WAD -> 6dp). The single definition used by
    ///      `_buyOption`'s pull and by `quoteBest`'s solvency filter — a quote that applies a
    ///      different threshold than the buy would hand out unfillable quotes.
    function capBacking(uint256 cap, uint256 size) public pure returns (uint256) {
        return F.fullMulDiv(cap, size, 1e30);
    }

    /// @notice How much quote-token backing a maker can ACTUALLY honour under this strategy.
    /// @dev The `min` is the whole point of this function.
    ///
    ///      `AQUA.ship` only writes an accounting entry. No ERC-20 moves at ship time — the
    ///      tokens leave the maker's own wallet later, when the app calls `AQUA.pull` inside
    ///      `buyOption`. So the two numbers below are independent and can disagree:
    ///
    ///        aquaCommitted — what Aqua's books say the maker has promised this strategy
    ///        walletBalance — what the maker's wallet can actually deliver at pull time
    ///
    ///      When `walletBalance < aquaCommitted` the maker looks fully collateralised on
    ///      Aqua's books and `buyOption` still reverts deep inside Aqua with
    ///      `ERC20InsufficientBalance`. We hit exactly that on the live Base Sepolia deploy
    ///      (shipped collateral whose backing had been spent seeding the v4 pool). Solvency is
    ///      therefore the MINIMUM of the promise and the means, never either one alone.
    /// @return aquaCommitted Collateral committed to this strategy on Aqua's books.
    /// @return walletBalance The maker's actual quote-token wallet balance.
    /// @return backable min(aquaCommitted, walletBalance) — what a buy can really pull.
    function makerCapacity(Strategy calldata s)
        public
        view
        returns (uint256 aquaCommitted, uint256 walletBalance, uint256 backable)
    {
        (uint248 committed,) = AQUA.rawBalances(s.maker, address(this), hashStrategy(s), s.quote);
        aquaCommitted = uint256(committed);
        walletBalance = IERC20(s.quote).balanceOf(s.maker);
        backable = aquaCommitted < walletBalance ? aquaCommitted : walletBalance;
    }

    /// @notice Cheapest solvent maker for a set of candidate strategies.
    /// @dev Aqua IS the order book: every maker who ever shipped is recoverable from
    ///      `IAqua.Shipped(maker, app, strategyHash, strategy)` logs, which carry the full
    ///      abi-encoded `Strategy`. A caller decodes those into `ss` and asks this function
    ///      who is cheapest — no registry, no indexer, no CLOB.
    ///
    ///      `quotePremium` never reads `s.maker`, so two makers quoting the same terms differ
    ///      only by their `volWad`. That is deliberate: implied vol is the competitive axis
    ///      makers undercut each other on, exactly as they would on a real options book.
    ///
    ///      A candidate is skipped if it is not bound to this app, or if its `backable`
    ///      (see `makerCapacity`) cannot cover `capBacking(cap, size)` — the same threshold
    ///      `_buyOption` pulls at, so a returned quote is one that can actually be filled.
    /// @return bestIndex Index into `ss`, or `type(uint256).max` when nobody qualifies.
    /// @return bestPremium Premium in quote-token units, 0 when nobody qualifies.
    /// @return bestMaker The winning maker, `address(0)` when nobody qualifies.
    function quoteBest(
        Strategy[] calldata ss,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size
    ) external view returns (uint256 bestIndex, uint256 bestPremium, address bestMaker) {
        // Sentinel up front: no revert on an empty market, the frontend renders
        // "no maker available" instead of eating a failed call.
        bestIndex = type(uint256).max;
        uint256 need = capBacking(cap, size);

        for (uint256 i; i < ss.length; ++i) {
            if (!_isSolvent(ss[i], need)) continue;
            uint256 premium = quotePremium(ss[i], kind, strike, cap, expiry, size);
            if (bestIndex == type(uint256).max || premium < bestPremium) {
                bestIndex = i;
                bestPremium = premium;
                bestMaker = ss[i].maker;
            }
        }
    }

    /// @dev Candidate filter for `quoteBest`, extracted to keep that loop's stack shallow
    ///      (this file is compiled without via_ir).
    function _isSolvent(Strategy calldata s, uint256 need) internal view returns (bool) {
        if (s.app != address(this)) return false;
        (,, uint256 backable) = makerCapacity(s);
        return backable >= need;
    }

    /// @dev Reverts unless the strategy is bound to this app.
    function _validateStrategy(Strategy calldata s) internal view {
        if (s.app != address(this)) revert NotThisApp();
    }

    /// @notice Permissionlessly settle an expired position in USDC cash.
    /// @dev Signature widened from the brief's `settle(uint256)`:
    ///      - `Strategy calldata s`: `Position` stores only `strategyHash`, not the pool
    ///        id / decimals / orientation that `_sampleSpot` needs. The maker-supplied
    ///        strategy carries those (as `buyOption` does); we re-derive its hash and
    ///        require it to match, keeping `Position` lean.
    ///      - `address holder`: the ERC-1155 is fungible per positionId and has no
    ///        enumeration, so the caller names the holder to pay. The whole position is
    ///        settled for that holder.
    ///      Custody follows the committed model (Rulings 2+3+4): the app already pulled
    ///      and HOLDS `capBacking` USDC at `buyOption`. Settlement pays the holder from
    ///      that held balance and returns the remainder to the maker — there is NO second
    ///      AQUA.pull. CEI: expiry/settled/hash checks, then effects (settled + burn),
    ///      then the two transfers.
    function settle(Strategy calldata s, uint256 positionId, address holder) external {
        Position storage p = positions[positionId];
        require(block.timestamp >= p.expiry, NotExpired());
        require(!p.settled, AlreadySettled());
        require(hashStrategy(s) == p.strategyHash, StrategyMismatch());

        uint256 spotWad = _sampleSpot(s);

        // Capped intrinsic payoff (realized spot, NOT Black-Scholes).
        uint256 intrinsicWad;
        if (p.kind == 0) {
            // CALL
            intrinsicWad = spotWad > p.strike ? spotWad - p.strike : 0;
        } else {
            // PUT
            intrinsicWad = p.strike > spotWad ? p.strike - spotWad : 0;
        }
        uint256 cappedWad = intrinsicWad > p.cap ? p.cap : intrinsicWad;
        uint256 payoutWadSized = F.mulWad(cappedWad, p.size);
        uint256 payout = F.mulDiv(payoutWadSized, 10 ** s.quoteDecimals, 1e18);

        // Safety invariant: payout = min(..,cap)*size <= cap*size == capBacking. Never trips.
        require(payout <= p.capBacking, PayoutExceedsBacking());
        uint256 remainder = p.capBacking - payout;

        // Effects before interactions.
        p.settled = true;
        _burn(holder, positionId, p.size);

        // Interactions: pay holder from held backing, return the remainder to the maker.
        if (payout > 0) {
            IERC20(p.quote).transfer(holder, payout);
        }
        if (remainder > 0) {
            IERC20(p.quote).transfer(p.maker, remainder);
        }

        emit OptionSettled(positionId, holder, spotWad, payout, remainder);
    }

    /// @notice Spot sampled for settlement, averaged over `SAMPLES` reads.
    /// @dev In a single tx no time passes, so every read of `UniV4Spot.spotWad` is
    ///      identical and the average equals one read. The loop is a deliberate hook
    ///      for a future multi-block window; today it is honestly a single read.
    function _sampleSpot(Strategy memory s) internal view returns (uint256 spotWad) {
        uint256 acc;
        for (uint256 i = 0; i < SAMPLES; ++i) {
            acc += UniV4Spot.spotWad(
                STATE_VIEW, s.poolId, s.underlyingDecimals, s.quoteDecimals, s.underlyingIsCurrency0
            );
        }
        spotWad = acc / SAMPLES;
    }
}
