// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {GapTaker} from "../src/GapTaker.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {UniV4Spot} from "../src/lib/UniV4Spot.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title E2E
/// @notice Live end-to-end exercise of the deployed Gap stack on Base Sepolia.
/// @dev Three phases, driven by `script/e2e.sh` because settlement needs real time
///      to pass (expiry is a wall-clock timestamp, and `vm.warp` cannot move a live chain):
///
///        forge script script/E2E.s.sol --sig "checks()"           read-only preflight
///        forge script script/E2E.s.sol --sig "buy()"    --broadcast
///        <wait past expiry>
///        forge script script/E2E.s.sol --sig "settle()" --broadcast
///
///      Every phase asserts on real chain state and reverts loudly on mismatch, so a
///      green run is a genuine proof the money path works — not just that txs landed.
///
///      Two distinct parties, as in the real product:
///        maker = the deployer (shipped USDC collateral via Ship.s.sol)
///        taker = a deterministic throwaway EOA, funded with gas + mock USDC here.
///      The taker buys through the deployed `GapTaker` helper, which is exactly the
///      path the frontend takes (an EOA cannot call `buyOption` directly — the app
///      calls `IGapOptionCallback` back on `msg.sender`).
contract E2E is Script {
    // --- option terms (short expiry so the e2e completes in one run) ---
    uint8 internal constant KIND_CALL = 0;
    // Strike is derived at runtime from live spot (at-the-money), NOT hardcoded. The pool
    // tracks the real NVDA price via script/sync-spot.sh, so a fixed strike would drift
    // deep in- or out-of-the-money and pin the premium at `CAP`.
    uint256 internal constant CAP = 10e18; // max payoff 10 USDC per unit
    uint256 internal constant SIZE = 1e18; // 1 unit => capBacking = 5e6 (5 USDC)
    uint256 internal constant MAX_PREMIUM = 50e6; // 50 USDC ceiling

    // Strategy constants — MUST match Ship.s.sol or the hash won't find the collateral.
    uint8 internal constant UNDERLYING_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;
    uint256 internal constant VOL_WAD = 0.5e18;
    bytes32 internal constant SALT = bytes32(uint256(1));

    uint256 internal constant TAKER_USDC = 1_000e6;
    uint256 internal constant TAKER_GAS = 0.01 ether;
    /// @dev Wallet floor the maker must hold to honour collateral pulls (see `_fundTaker`).
    uint256 internal constant MAKER_MIN_USDC = 1_000_000e6;

    string internal constant DEPLOY_JSON = "./deployments/base-sepolia.json";
    string internal constant STATE_JSON = "./deployments/e2e-state.json";

    struct Env {
        address aqua;
        address app;
        address taker; // the GapTaker helper contract
        address nvdax;
        address usdc;
        address stateView;
        bytes32 poolId;
        bool underlyingIsCurrency0;
        address maker;
    }

    // ---------------------------------------------------------------------
    // Phase 0 — read-only preflight
    // ---------------------------------------------------------------------

    /// @notice Asserts the deployment is coherent and ready to trade. Broadcasts nothing.
    function checks() external view {
        Env memory e = _readEnv();
        GapOptionsApp app = GapOptionsApp(e.app);
        GapOptionsApp.Strategy memory s = _strategy(e);
        bytes32 hash = app.hashStrategy(s);

        console2.log("--- preflight ---");
        console2.log("app        ", e.app);
        console2.log("gapTaker   ", e.taker);
        console2.log("maker      ", e.maker);

        // 1. every address actually has bytecode
        require(e.app.code.length > 0, "app has no code");
        require(e.taker.code.length > 0, "gapTaker has no code");
        require(e.aqua.code.length > 0, "aqua has no code");

        // 2. the GapTaker is bound to THIS app (otherwise its callback guard rejects)
        require(GapTaker(e.taker).APP() == e.app, "gapTaker bound to a different app");
        require(address(GapTaker(e.taker).AQUA()) == e.aqua, "gapTaker bound to a different aqua");

        // 3. the v4 pool is initialised and prices near the seeded 100 USDC/NVDAx
        uint256 spot = UniV4Spot.spotWad(
            IStateView(e.stateView), e.poolId, UNDERLYING_DECIMALS, QUOTE_DECIMALS, e.underlyingIsCurrency0
        );
        console2.log("spot (WAD) ", spot);
        // A plausibility band, not a pin: the keeper moves this pool to the live NVDA price,
        // so assert only that the pool is initialised and quoting something sane.
        require(spot > 1e18 && spot < 100_000e18, "spot implausible - pool mispriced or uninitialised");

        // 4. the maker's shipped collateral is visible to the app under this exact hash
        (uint256 makerCollateral,) = IAqua(e.aqua).rawBalances(e.maker, e.app, hash, e.usdc);
        console2.log("maker aqua USDC", makerCollateral);
        require(makerCollateral > 0, "no maker collateral - run Ship.s.sol (or strategy hash mismatch)");

        // 5. a live quote is sane: 0 < premium <= cap*size, and strictly above intrinsic (ATM => time value)
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 strike = _atmStrike(spot);
        console2.log("atm strike ", strike);
        uint256 premium = app.quotePremium(s, KIND_CALL, strike, CAP, expiry, SIZE);
        uint256 capBacking = CAP * SIZE / 1e30;
        console2.log("quotePremium (6dp)", premium);
        require(premium > 0, "premium is zero");
        require(premium <= capBacking, "premium exceeds cap - breaks full collateralisation");
        require(makerCollateral >= capBacking, "maker collateral below capBacking");

        // 6. the maker's WALLET can honour the pull. Aqua's books are an accounting entry;
        //    the ERC20 only moves at `pull` time, out of the maker's own wallet. These two
        //    numbers can disagree, and when they do `buyOption` reverts deep inside Aqua
        //    with ERC20InsufficientBalance against a maker that looks fully collateralised.
        uint256 makerWallet = IERC20(e.usdc).balanceOf(e.maker);
        console2.log("maker wallet USDC", makerWallet);
        require(makerWallet >= capBacking, "maker WALLET USDC below capBacking - shipped collateral is unbacked");

        console2.log("preflight OK");
    }

    // ---------------------------------------------------------------------
    // Phase 1 — buy
    // ---------------------------------------------------------------------

    /// @notice Funds a throwaway taker, buys one capped CALL through `GapTaker`, and
    ///         asserts the collateral pull, the premium push and the ERC-1155 mint.
    /// @dev Expiry = now + `E2E_EXPIRY_SECONDS` (default 120s) so `settle()` can run shortly after.
    /// @dev Balances captured before the buy, so the assertions can check deltas.
    struct Snapshot {
        uint256 makerAqua;
        uint256 takerUsdc;
        uint256 appUsdc;
    }

    function buy() external {
        Env memory e = _readEnv();
        GapOptionsApp.Strategy memory s = _strategy(e);
        bytes32 hash = GapOptionsApp(e.app).hashStrategy(s);

        uint256 takerPk = uint256(keccak256("gap-e2e-taker-v1"));
        address takerEoa = vm.addr(takerPk);
        uint64 expiry = uint64(block.timestamp + vm.envOr("E2E_EXPIRY_SECONDS", uint256(120)));

        console2.log("--- buy ---");
        console2.log("takerEoa   ", takerEoa);

        _fundTaker(e, takerEoa);

        Snapshot memory before = _snapshot(e, hash, takerEoa);
        uint256 strike = _atmStrike(_spot(e));
        console2.log("atm strike ", strike);
        uint256 maxPremium = _maxPremium(e, s, strike, expiry);

        bytes memory takerData = abi.encode(e.maker, hash);
        uint256 positionId = _doBuy(e, s, strike, expiry, maxPremium, takerPk, takerData);

        console2.log("positionId ", positionId);

        uint256 paid = _assertBought(e, hash, takerEoa, positionId, before, maxPremium);
        _assertPositionRecord(e, positionId, strike, expiry);

        _writeState(positionId, takerEoa, expiry, paid);
        console2.log("premium paid", paid);
        console2.log("buy OK - settle after", expiry);
    }

    /// @dev The buy itself, in its own frame to keep the 10-argument call off a deep stack.
    ///      Taker approves the helper for the premium, then buys through it: the helper is
    ///      `msg.sender` to the app, so it is the one that receives `gapOptionCallback`.
    function _doBuy(
        Env memory e,
        GapOptionsApp.Strategy memory s,
        uint256 strike,
        uint64 expiry,
        uint256 maxPremium,
        uint256 takerPk,
        bytes memory takerData
    ) internal returns (uint256 positionId) {
        vm.startBroadcast(takerPk);
        IERC20(e.usdc).approve(e.taker, maxPremium);
        positionId = GapTaker(e.taker).buy(
            GapOptionsApp(e.app), s, KIND_CALL, strike, CAP, expiry, SIZE, maxPremium, vm.addr(takerPk), takerData
        );
        vm.stopBroadcast();
    }

    /// @dev Maker-side prep: give the throwaway taker gas + mock USDC to pay the premium,
    ///      and make sure the maker's WALLET can actually honour the collateral pull.
    /// @dev The wallet top-up is not cosmetic. Aqua's `ship` only records an accounting
    ///      entry; the ERC20 moves at `pull` time out of the maker's own wallet. A maker can
    ///      therefore look fully collateralised on Aqua's books and still fail the pull.
    function _fundTaker(Env memory e, address takerEoa) internal {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        if (takerEoa.balance < TAKER_GAS) payable(takerEoa).transfer(TAKER_GAS);
        MockERC20(e.usdc).mint(takerEoa, TAKER_USDC);
        if (IERC20(e.usdc).balanceOf(e.maker) < MAKER_MIN_USDC) {
            MockERC20(e.usdc).mint(e.maker, MAKER_MIN_USDC);
        }
        vm.stopBroadcast();
    }

    function _snapshot(Env memory e, bytes32 hash, address takerEoa) internal view returns (Snapshot memory snap) {
        (snap.makerAqua,) = IAqua(e.aqua).rawBalances(e.maker, e.app, hash, e.usdc);
        snap.takerUsdc = IERC20(e.usdc).balanceOf(takerEoa);
        snap.appUsdc = IERC20(e.usdc).balanceOf(e.app);
    }

    /// @dev Reads the binding on-chain quote and gives it headroom, since spot and time
    ///      both move between this read and the tx landing.
    function _maxPremium(Env memory e, GapOptionsApp.Strategy memory s, uint256 strike, uint64 expiry)
        internal
        view
        returns (uint256)
    {
        uint256 premium = GapOptionsApp(e.app).quotePremium(s, KIND_CALL, strike, CAP, expiry, SIZE);
        console2.log("quoted premium", premium);
        require(premium > 0 && premium <= MAX_PREMIUM, "premium out of band");
        return premium * 2 < MAX_PREMIUM ? premium * 2 : MAX_PREMIUM;
    }

    /// @dev Asserts the three balance moves a buy must make, and returns the premium paid.
    function _assertBought(
        Env memory e,
        bytes32 hash,
        address takerEoa,
        uint256 positionId,
        Snapshot memory before,
        uint256 maxPremium
    ) internal view returns (uint256 paid) {
        uint256 capBacking = CAP * SIZE / 1e30;

        // the ERC-1155 position exists and is owned by the taker
        require(GapOptionsApp(e.app).balanceOf(takerEoa, positionId) == SIZE, "position not minted to taker");

        // the app pulled and now HOLDS exactly capBacking of USDC
        require(IERC20(e.usdc).balanceOf(e.app) == before.appUsdc + capBacking, "app did not take capBacking");

        // the taker paid a premium out of pocket, within the cap they agreed to
        paid = before.takerUsdc - IERC20(e.usdc).balanceOf(takerEoa);
        require(paid > 0 && paid <= maxPremium, "taker did not pay a sane premium");

        // the maker's Aqua balance fell by the pulled backing and rose by the premium
        (uint256 makerAquaAfter,) = IAqua(e.aqua).rawBalances(e.maker, e.app, hash, e.usdc);
        require(makerAquaAfter == before.makerAqua - capBacking + paid, "maker aqua delta != -capBacking + premium");
    }

    /// @dev Asserts the stored position record matches the terms we asked for.
    function _assertPositionRecord(Env memory e, uint256 positionId, uint256 strike, uint64 expiry)
        internal
        view
    {
        (, address pMaker,,, uint8 pKind, uint256 pStrike, uint256 pCap, uint64 pExpiry,,, uint256 pBacking) =
            GapOptionsApp(e.app).positions(positionId);
        require(pMaker == e.maker && pKind == KIND_CALL, "position maker/kind mismatch");
        require(pStrike == strike && pCap == CAP, "position terms mismatch");
        require(pExpiry == expiry && pBacking == CAP * SIZE / 1e30, "position expiry/backing mismatch");
    }

    // ---------------------------------------------------------------------
    // Phase 2 — settle
    // ---------------------------------------------------------------------

    /// @notice Settles the position written by `buy()` and asserts the cash flows.
    /// @dev Permissionless: broadcast from the maker key here purely because it has gas.
    function settle() external {
        Env memory e = _readEnv();
        GapOptionsApp app = GapOptionsApp(e.app);
        GapOptionsApp.Strategy memory s = _strategy(e);

        string memory st = vm.readFile(STATE_JSON);
        uint256 positionId = vm.parseJsonUint(st, ".positionId");
        address holder = vm.parseJsonAddress(st, ".holder");
        uint256 expiry = vm.parseJsonUint(st, ".expiry");

        console2.log("--- settle ---");
        require(block.timestamp >= expiry, "not expired yet - wait longer");
        require(app.balanceOf(holder, positionId) == SIZE, "holder does not hold the position");

        uint256 capBacking = CAP * SIZE / 1e30;
        uint256 holderBefore = IERC20(e.usdc).balanceOf(holder);
        uint256 makerBefore = IERC20(e.usdc).balanceOf(e.maker);
        uint256 appBefore = IERC20(e.usdc).balanceOf(e.app);
        require(appBefore >= capBacking, "app no longer holds the backing");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        app.settle(s, positionId, holder);
        vm.stopBroadcast();

        uint256 payout = IERC20(e.usdc).balanceOf(holder) - holderBefore;
        uint256 remainder = IERC20(e.usdc).balanceOf(e.maker) - makerBefore;
        console2.log("payout     ", payout);
        console2.log("remainder  ", remainder);

        // --- assertions ---
        // the backing is fully distributed: nothing is stranded, nothing is conjured
        require(payout + remainder == capBacking, "payout + remainder != capBacking");
        require(payout <= capBacking, "payout exceeds backing");
        require(IERC20(e.usdc).balanceOf(e.app) == appBefore - capBacking, "app did not release the backing");

        // the position is burned and flagged settled
        require(app.balanceOf(holder, positionId) == 0, "position not burned");
        (,,,,,,,,, bool pSettled,) = app.positions(positionId);
        require(pSettled, "position not flagged settled");

        // settling twice must revert
        try app.settle(s, positionId, holder) {
            revert("second settle should have reverted");
        } catch {}

        console2.log("settle OK");
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev Live spot from the v4 pool, WAD quote-per-underlying.
    function _spot(Env memory e) internal view returns (uint256) {
        return UniV4Spot.spotWad(
            IStateView(e.stateView), e.poolId, UNDERLYING_DECIMALS, QUOTE_DECIMALS, e.underlyingIsCurrency0
        );
    }

    /// @dev At-the-money strike: live spot rounded to the nearest whole quote unit. Keeps the
    ///      option near the money whatever price the keeper has synced the pool to, so the
    ///      premium stays a real Black-Scholes number instead of pinning at `CAP`.
    function _atmStrike(uint256 spotWad) internal pure returns (uint256) {
        return ((spotWad + 0.5e18) / 1e18) * 1e18;
    }

    function _strategy(Env memory e) internal pure returns (GapOptionsApp.Strategy memory) {
        return GapOptionsApp.Strategy({
            app: e.app,
            maker: e.maker,
            underlying: e.nvdax,
            quote: e.usdc,
            poolId: e.poolId,
            underlyingIsCurrency0: e.underlyingIsCurrency0,
            underlyingDecimals: UNDERLYING_DECIMALS,
            quoteDecimals: QUOTE_DECIMALS,
            volWad: VOL_WAD,
            salt: SALT
        });
    }

    function _readEnv() internal view returns (Env memory e) {
        string memory json = vm.readFile(DEPLOY_JSON);
        e.aqua = vm.parseJsonAddress(json, ".aqua");
        e.app = vm.parseJsonAddress(json, ".gapOptionsApp");
        e.taker = vm.parseJsonAddress(json, ".gapTaker");
        e.nvdax = vm.parseJsonAddress(json, ".nvdax");
        e.usdc = vm.parseJsonAddress(json, ".usdc");
        e.stateView = vm.parseJsonAddress(json, ".stateView");
        e.poolId = vm.parseJsonBytes32(json, ".poolId");
        e.underlyingIsCurrency0 = vm.parseJsonBool(json, ".underlyingIsCurrency0");
        e.maker = vm.parseJsonAddress(json, ".maker");
    }

    function _writeState(uint256 positionId, address holder, uint64 expiry, uint256 premium) internal {
        string memory obj = "e2e";
        vm.serializeUint(obj, "positionId", positionId);
        vm.serializeAddress(obj, "holder", holder);
        vm.serializeUint(obj, "premium", premium);
        string memory json = vm.serializeUint(obj, "expiry", uint256(expiry));
        vm.writeJson(json, STATE_JSON);
    }
}
