// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { WeekendOptions } from "../WeekendOptions.sol";
import { IGapOptionCallback } from "../interfaces/IGapOptionCallback.sol";
import { IMakerHooks } from "../interfaces/IMakerHooks.sol";

/// @dev `WeekendOptions.close` is owned by a concurrent workstream and is called through this
/// one-function view of the app rather than the concrete type. The indirection is deliberate:
/// see `_tryClose` — the desk must survive `close` reverting, and must not fail to compile
/// before the core lands it.
interface IWeekendClose {
    function close(uint256 seriesId, uint256 amount) external;
}

/// @title WeekendDesk
/// @notice The option market maker. One contract, two roles.
///
/// 1. **SwapVM maker.** It is `order.maker` on the resting quotes shipped to Aqua, and SwapVM
///    calls back into `preTransferOut` / `postTransferIn` around the two token transfers.
/// 2. **Core-protocol maker.** It is also a `WeekendOptions` writer, so it can mint option
///    tokens just-in-time against its own collateral inside the first of those hooks.
///
/// ```
/// preTransferOut   ASK (tokenOut != quote) -> mint the shortfall, enforce the short cap
///                  BID (tokenOut == quote) -> nothing; the pull fails if the quote is not here
/// postTransferIn   ASK (tokenIn  == quote) -> nothing; the premium is already collateral
///                  BID (tokenIn  != quote) -> close against `written`, best-effort
/// ```
///
/// @dev FOUR THINGS THAT ARE LOAD-BEARING. None is a style choice.
///
/// **`active` is checked in BOTH hooks.** The reference desk checks it only in
/// `preTransferOut`, which is safe there solely because ERC-1271 rejects a dead maker's
/// signature first. There is no signature on the Aqua path (`useAquaInsteadOfSignature`), so
/// that gap goes live. Both hooks share `onlyFill`, which is where the check lives.
///
/// **Transfer ordering is the TAKER's choice.** `IS_FIRST_TRANSFER_FROM_TAKER` (`0x0020`) is a
/// *taker* trait; the maker cannot force or forbid it. So `preTransferOut` may run before or
/// after `postTransferIn` for the same fill. Nothing below reads a balance that only exists
/// once the counter-leg has landed: the ask mints against collateral already in the wallet,
/// and the bid closes against `written`, not against the premium.
///
/// **Minting does not credit the Aqua ledger.** `AQUA.pull` is a real `transferFrom` out of
/// this wallet, which is the only reason a token minted in `preTransferOut` is pullable one
/// call later. The ledger still decrements from the amount shipped, so the shipped option
/// balance *is* the cumulative written cap, and `approveAqua` is mandatory — without it every
/// ask fill reverts inside `AQUA.pull`.
///
/// **There is no `writeFor` on the core.** The only write path is `buyOption`, which pulls
/// collateral via Aqua and demands an `IGapOptionCallback` premium push. The desk therefore
/// ships a *third* Aqua strategy of its own (`setOwnStrategy`) and buys from itself: maker and
/// taker are both this contract, so the premium leg is a desk -> desk transfer that nets to
/// zero. If the core ever grows a `writeFor(seriesId, amount, to)` that takes collateral
/// straight from the caller's wallet, delete `gapOptionCallback` and the own-strategy plumbing
/// and call that instead.
contract WeekendDesk is IMakerHooks, IGapOptionCallback, Ownable2Step {
    using SafeERC20 for IERC20;

    WeekendOptions public immutable APP;
    IAqua public immutable AQUA;
    /// @notice The `AquaSwapVMRouter`. The only address allowed to call the hooks.
    address public immutable ROUTER;
    /// @notice The single quote token every series is priced in. Its position in the pair is
    /// what tells a hook whether this fill is an ask or a bid.
    address public immutable QUOTE;

    /// @notice Kill switch. Checked in both hooks.
    bool public active;

    /// @notice `seriesId + 1`, so 0 means "not listed". Filled by `listSeries`.
    mapping(address optionToken => uint256 seriesIdPlusOne) public seriesOfToken;
    /// @notice Per-series ceiling on `written[id][desk]`, checked after each write.
    mapping(uint256 seriesId => uint256 cap) public maxShort;

    /// @notice The desk's own core-protocol collateral strategy, used for the self-write.
    WeekendOptions.Strategy internal _ownStrategy;
    bytes32 public ownStrategyHash;

    error NotRouter();
    error NotMaker();
    error NotApp();
    error Inactive();
    error UnknownToken(address token);
    error ShortLimit(uint256 seriesId, uint256 short, uint256 cap);
    error BadPair();
    error BadStrategy();
    error LengthMismatch();
    error UnusedHook();

    event Sold(uint256 indexed seriesId, address indexed taker, uint256 amountOut, uint256 amountIn, uint256 minted);
    event BoughtBack(
        uint256 indexed seriesId, address indexed taker, uint256 amountIn, uint256 amountOut, uint256 closed
    );
    /// @notice Emitted when `close` reverted and the options were kept as inventory instead.
    /// @dev Not an error: see `_tryClose`.
    event CloseSkipped(uint256 indexed seriesId, uint256 amount);
    event SeriesListed(uint256 indexed seriesId, address indexed optionToken, uint256 maxShort);
    event ActiveSet(bool active);

    constructor(WeekendOptions app_, IAqua aqua_, address router_, address quote_) Ownable(msg.sender) {
        APP = app_;
        AQUA = aqua_;
        ROUTER = router_;
        QUOTE = quote_;
        active = true;
    }

    // ---------------------------------------------------------------- admin

    function setActive(bool active_) external onlyOwner {
        active = active_;
        emit ActiveSet(active_);
    }

    /// @notice Open the desk for a set of series and give each one a short cap.
    function listSeries(uint256[] calldata ids, uint256[] calldata maxShort_) external onlyOwner {
        if (ids.length != maxShort_.length) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            address token = address(APP.getSeries(ids[i]).token);
            seriesOfToken[token] = ids[i] + 1;
            maxShort[ids[i]] = maxShort_[i];
            emit SeriesListed(ids[i], token, maxShort_[i]);
        }
    }

    /// @notice Point the self-write at the desk's own shipped collateral strategy.
    /// @dev The strategy must be shipped to Aqua separately (`AQUA.ship(APP, abi.encode(s), ...)`
    /// from this contract) with both the collateral token and the quote token present — `push`
    /// reverts with `PushToNonActiveStrategyPrevented` on a token that is not in the strategy,
    /// and the premium leg is a quote push.
    ///
    /// `maker` and `app` are pinned rather than trusted: a strategy naming someone else would
    /// pull *their* collateral and accrue `written` to *them*, which would silently detach the
    /// short cap below from the position it is supposed to bound.
    ///
    /// One strategy means one `underlying` (`buyOption` reverts `StrategyMismatch` otherwise),
    /// so a desk serving two underlyings needs two deployments today.
    function setOwnStrategy(WeekendOptions.Strategy calldata s) external onlyOwner {
        if (s.maker != address(this) || s.app != address(APP) || s.quote != QUOTE) revert BadStrategy();
        _ownStrategy = s;
        ownStrategyHash = APP.hashStrategy(s);
    }

    function ownStrategy() external view returns (WeekendOptions.Strategy memory) {
        return _ownStrategy;
    }

    /// @notice REQUIRED before any fill. `AQUA.pull` is a `transferFrom` out of this wallet.
    function approveAqua(address token, uint256 amount) external onlyOwner {
        IERC20(token).forceApprove(address(AQUA), amount);
    }

    /// @notice Escape hatch for collateral unlocked by `close`, `claim` or a docked strategy.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- hooks

    /// @dev Every hook entry point. `maker == address(this)` is not redundant with the router
    /// check: SwapVM passes `order.maker` straight through, so a hook target shared by several
    /// makers would otherwise act on another maker's fill.
    modifier onlyFill(address maker) {
        if (msg.sender != ROUTER) revert NotRouter();
        if (maker != address(this)) revert NotMaker();
        if (!active) revert Inactive();
        _;
    }

    /// @inheritdoc IMakerHooks
    function preTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external onlyFill(maker) {
        (uint256 id, bool ask) = _resolve(tokenIn, tokenOut);
        // BID: the desk owes quote. Nothing to prepare — if the quote is not in the wallet the
        // `AQUA.pull` that follows this hook reverts on its own, which is the correct answer.
        if (ask) _sell(id, taker, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc IMakerHooks
    function postTransferIn(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external onlyFill(maker) {
        (uint256 id, bool ask) = _resolve(tokenIn, tokenOut);
        // ASK: the premium has landed in the wallet, where it already is collateral for the
        // next write. Deliberately nothing to do — and nothing above this line read it.
        if (!ask) _buyBack(id, taker, amountIn, amountOut);
    }

    /// @dev Unused. Fail closed if an order is ever shipped with these flags set.
    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
        external
        pure
    {
        revert UnusedHook();
    }

    /// @dev Unused. Fail closed if an order is ever shipped with these flags set.
    function postTransferOut(
        address,
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure {
        revert UnusedHook();
    }

    // ---------------------------------------------------------------- internals

    /// @dev The ask branch of `preTransferOut`, split out only to keep the hook's stack under
    /// the limit — the default profile builds without `via_ir`.
    function _sell(uint256 id, address taker, address optionToken, uint256 amountIn, uint256 amountOut) internal {
        emit Sold(id, taker, amountOut, amountIn, _mintShortfall(id, optionToken, amountOut));
    }

    /// @dev The bid branch of `postTransferIn`. Split out for the same reason as `_sell`.
    function _buyBack(uint256 id, address taker, uint256 amountIn, uint256 amountOut) internal {
        emit BoughtBack(id, taker, amountIn, amountOut, _tryClose(id, amountIn));
    }

    /// @dev Which series this pair trades, and which way round. The quote token's side of the
    /// pair is the whole signal; the pricer enforces that it matches the side the maker
    /// shipped, so a hook never has to.
    /// @return id The series id.
    /// @return ask True when the desk is selling options (quote in, option out).
    function _resolve(address tokenIn, address tokenOut) internal view returns (uint256 id, bool ask) {
        address optionToken;
        if (tokenIn == QUOTE) {
            (optionToken, ask) = (tokenOut, true);
        } else if (tokenOut == QUOTE) {
            (optionToken, ask) = (tokenIn, false);
        } else {
            revert BadPair();
        }
        uint256 listed = seriesOfToken[optionToken];
        if (listed == 0) revert UnknownToken(optionToken);
        id = listed - 1;
    }

    /// @dev Cover `amountOut` option tokens, minting only what inventory does not already
    /// cover. Inventory exists because the bid side buys options back faster than it can
    /// `close` them (see `_tryClose`), and spending it first is what keeps `written` from
    /// ratcheting up on a desk that is actually flat.
    ///
    /// The cap is checked AFTER the write and against the cumulative `written[id][desk]`, not
    /// against this fill: the Aqua ledger is the only per-order bound, and it is cumulative
    /// too. A per-fill check would let many small fills walk straight past it.
    function _mintShortfall(uint256 id, address optionToken, uint256 amountOut) internal returns (uint256 minted) {
        uint256 held = IERC20(optionToken).balanceOf(address(this));
        if (held >= amountOut) return 0;
        minted = amountOut - held;

        // maxPremium is unbounded on purpose: the premium is desk -> desk and nets to zero.
        // takerData is what `WeekendTaker` would pass — (maker, strategyHash) — read back by
        // this contract's own `gapOptionCallback`.
        APP.buyOption(
            _ownStrategy, id, minted, type(uint256).max, address(this), abi.encode(address(this), ownStrategyHash)
        );

        uint256 short = APP.written(id, address(this));
        uint256 cap = maxShort[id];
        if (short > cap) revert ShortLimit(id, short, cap);
    }

    /// @dev Unwind at most what the desk actually wrote, and TOLERATE FAILURE.
    ///
    /// Two independent reasons the amount is capped and the call is wrapped:
    ///
    /// 1. `close` can only burn against the caller's own `written`, so a taker selling back
    ///    more than the desk ever wrote (options written by someone else, bought elsewhere)
    ///    would revert the whole fill. The excess stays as inventory and is spent by the next
    ///    ask instead — same economics, no mint.
    ///
    /// 2. **`close` is currently extractable** (spec §10, OPEN HAZARD). It pays pro-rata of
    ///    BOTH pool legs on the PRE-decrement `totalWritten`, so a writer entering a CALL
    ///    series after exercises can close immediately for a profit at every spot below the
    ///    strike, at the expense of existing writers. The two candidate fixes both change
    ///    `close`'s failure surface — candidate 2 bars `close` outright once the opposite leg
    ///    is non-empty. Either way, a desk that *required* `close` to succeed would have its
    ///    whole bid side go dark the first time anyone exercised. So a revert here is absorbed:
    ///    the options are kept as inventory, the taker is still paid, and `written` is unwound
    ///    on some later fill (or at settlement via `claim`).
    ///
    /// The cost of absorbing it is that collateral stays locked longer than necessary. That is
    /// strictly better than a bid side that cannot be filled. Revisit once §10 is decided.
    function _tryClose(uint256 id, uint256 amountIn) internal returns (uint256 closed) {
        uint256 written = APP.written(id, address(this));
        closed = amountIn < written ? amountIn : written;
        if (closed == 0) return 0;

        try IWeekendClose(address(APP)).close(id, closed) { }
        catch {
            emit CloseSkipped(id, closed);
            closed = 0;
        }
    }

    // ---------------------------------------------------------------- self-write callback

    /// @inheritdoc IGapOptionCallback
    /// @dev The desk is its own taker. `AQUA.push` is `safeTransferFrom(msg.sender, maker, ...)`
    /// with both sides equal to this contract, so no value moves; all it does is credit the
    /// quote leg of the desk's own strategy, which is what `_safeCheckAquaPush` looks for.
    ///
    /// The desk must still *hold* `premiumOwed` of the quote token for the duration of the
    /// transfer (ERC-20 checks the balance even on a self-transfer) and must have approved
    /// Aqua for it. Keep the own-strategy `volWad` low: it only sets how much quote has to sit
    /// idle here, never what anyone pays.
    function gapOptionCallback(address, address quoteToken, uint256 premiumOwed, bytes calldata) external {
        if (msg.sender != address(APP)) revert NotApp();
        IERC20(quoteToken).forceApprove(address(AQUA), premiumOwed);
        AQUA.push(address(this), address(APP), ownStrategyHash, quoteToken, premiumOwed);
    }
}
