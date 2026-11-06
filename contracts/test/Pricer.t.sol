// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { OptionTokenFactory } from "../src/OptionToken.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";
import { SwapQuery, SwapRegisters } from "../src/interfaces/IExtruction.sol";
import { WeekendPricer } from "../src/desk/WeekendPricer.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice Fixed-price oracle. The pricer only consumes `spot`, so settlement is unimplemented.
contract MockOracle is IPriceOracle {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function set(uint256 price_) external {
        price = price_;
    }

    function spot(address) external view returns (uint256, uint256) {
        return (price, block.timestamp);
    }

    function settlementPrice(address, uint64) external pure returns (uint256, bool) {
        return (0, false);
    }
}

/// @notice `WeekendPricer` is an `Extruction` target: SwapVM hands it the swap registers and it
/// fills in the missing amount. These tests call `extruction` directly with the structs the
/// router would pass, so they pin the arithmetic and the direction gate without a VM.
contract PricerTest is Test {
    WeekendOptions app;
    WeekendPricer pricer;
    MockOracle oracle;
    MockERC20 usdc;
    MockERC20 nvdax;

    uint64 expiry;
    uint256 callId;
    address optionToken;

    uint256 constant VOL = 0.5e18; // 50% annualised
    uint256 constant STRIKE = 205e6; // quote units per 1e18
    address constant TAKER = address(0xB0B);

    // Cached: reading these off the contract is an external call, which would consume a
    // pending `vm.expectRevert` before the call under test is made.
    uint8 ASK;
    uint8 BID;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);
        OptionTokenFactory factory = new OptionTokenFactory();
        oracle = new MockOracle(205e6); // at the money

        app = new WeekendOptions(address(usdc), factory, IAqua(address(0)), IPriceOracle(address(oracle)));
        pricer = new WeekendPricer(app, IPriceOracle(address(oracle)), address(usdc), 6);

        expiry = uint64(block.timestamp + 1 days);
        callId = app.createSeries(address(nvdax), expiry, Kind.CALL, STRIKE);
        optionToken = address(app.getSeries(callId).token);

        ASK = pricer.SIDE_ASK();
        BID = pricer.SIDE_BID();
    }

    // ------------------------------------------------------------------ helpers

    function _query(address tokenIn, address tokenOut, bool isExactIn) internal view returns (SwapQuery memory) {
        return SwapQuery({
            orderHash: bytes32(uint256(1)),
            maker: address(this),
            taker: TAKER,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isExactIn: isExactIn
        });
    }

    function _regs(uint256 amountIn, uint256 amountOut) internal pure returns (SwapRegisters memory) {
        return SwapRegisters({
            balanceIn: type(uint128).max,
            balanceOut: type(uint128).max,
            amountIn: amountIn,
            amountOut: amountOut,
            surcharge: 0
        });
    }

    function _args(uint8 side) internal view returns (bytes memory) {
        return abi.encode(callId, VOL, side);
    }

    // ------------------------------------------------------------------ pricing

    function test_atTheMoneyCallIsWorthMoreThanZeroAndLessThanSpot() public view {
        uint256 p = pricer.premiumPerOption(callId, VOL);
        assertGt(p, 0, "ATM call must have time value");
        assertLt(p, 205e6, "a call can never be worth more than the spot");
    }

    function test_higherVolCostsMore() public view {
        // Implied vol is the only axis two makers quoting the same series differ on, so this
        // monotonicity is what makes the cheapest-maker competition meaningful.
        assertGt(pricer.premiumPerOption(callId, 0.9e18), pricer.premiumPerOption(callId, 0.3e18));
    }

    function test_premiumRevertsOnceExpired() public {
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(WeekendPricer.SeriesExpired.selector, expiry));
        pricer.premiumPerOption(callId, VOL);
    }

    // ------------------------------------------------------------------ ask side

    function test_askExactIn_quoteBuysOptionsAtThePremium() public view {
        uint256 premium = pricer.premiumPerOption(callId, VOL);
        uint256 spend = 100e6; // 100 USDC

        (,, SwapRegisters memory out) = pricer.extruction(
            true, 7, _query(address(usdc), optionToken, true), _regs(spend, 0), _args(ASK), ""
        );

        assertEq(out.amountOut, (spend * 1e18) / premium, "options out = spend / premium");
        assertEq(out.amountIn, spend, "the taker-specified leg must be untouched");
    }

    function test_askExactOut_roundsTheMakerSReceiptUp() public view {
        uint256 premium = pricer.premiumPerOption(callId, VOL);
        uint256 want = 1e18 + 1; // deliberately not a round number of options

        (,, SwapRegisters memory out) = pricer.extruction(
            true, 7, _query(address(usdc), optionToken, false), _regs(0, want), _args(ASK), ""
        );

        uint256 exact = want * premium;
        assertEq(out.amountIn, exact / 1e18 + (exact % 1e18 == 0 ? 0 : 1), "ceil, in the maker's favour");
    }

    // ------------------------------------------------------------------ bid side

    function test_bidExactIn_optionsSellBackForQuote() public view {
        uint256 premium = pricer.premiumPerOption(callId, VOL);
        uint256 give = 3e18; // 3 options

        (,, SwapRegisters memory out) = pricer.extruction(
            true, 7, _query(optionToken, address(usdc), true), _regs(give, 0), _args(BID), ""
        );

        assertEq(out.amountOut, (give * premium) / 1e18, "floor, in the maker's favour");
    }

    function test_bidPaysLessThanAskCharges_whenVolIsTheSpread() public view {
        // A maker running both sides ships a higher vol on the ask than the bid; that gap is the
        // spread. Nothing else in the system enforces one, so this is the only thing standing
        // between a two-sided maker and being arbitraged flat.
        uint256 ask = pricer.premiumPerOption(callId, 0.6e18);
        uint256 bid = pricer.premiumPerOption(callId, 0.4e18);
        assertGt(ask, bid);
    }

    // ------------------------------------------------------------------ the gate

    function test_askOrderCannotBeFilledInReverse() public {
        // The security property: an ask order accrues quote in the maker's Aqua counter, and
        // without this gate that counter is a standing allowance to sell options back at the
        // maker's own ask price.
        vm.expectRevert(
            abi.encodeWithSelector(WeekendPricer.WrongSwapDirection.selector, optionToken, address(usdc))
        );
        pricer.extruction(
            true, 7, _query(optionToken, address(usdc), true), _regs(1e18, 0), _args(ASK), ""
        );
    }

    function test_bidOrderCannotBeFilledInReverse() public {
        vm.expectRevert(
            abi.encodeWithSelector(WeekendPricer.WrongSwapDirection.selector, address(usdc), optionToken)
        );
        pricer.extruction(
            true, 7, _query(address(usdc), optionToken, true), _regs(1e18, 0), _args(BID), ""
        );
    }

    function test_rejectsAForeignTokenPair() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectRevert(
            abi.encodeWithSelector(WeekendPricer.WrongSwapDirection.selector, address(usdc), address(other))
        );
        pricer.extruction(
            true, 7, _query(address(usdc), address(other), true), _regs(1e18, 0), _args(ASK), ""
        );
    }

    function test_rejectsAnUnknownSide() public {
        vm.expectRevert(abi.encodeWithSelector(WeekendPricer.UnknownSide.selector, uint8(2)));
        pricer.extruction(
            true, 7, _query(address(usdc), optionToken, true), _regs(1e18, 0), abi.encode(callId, VOL, uint8(2)), ""
        );
    }

    // ------------------------------------------------------------------ VM contract

    function test_leavesProgramCounterAndTakerArgsAlone() public view {
        (uint256 nextPC, uint256 chopped,) = pricer.extruction(
            true, 7, _query(address(usdc), optionToken, true), _regs(100e6, 0), _args(ASK), ""
        );
        assertEq(nextPC, 7, "must not jump");
        assertEq(chopped, 0, "must not consume taker args");
    }

    function test_neverWidensTheMakerSBalances() public view {
        // The maker's spend ceiling comes from Aqua's preloaded balances. If this contract ever
        // raised them it would be handing out an allowance nobody granted.
        SwapRegisters memory inRegs = _regs(100e6, 0);
        (,, SwapRegisters memory out) = pricer.extruction(
            true, 7, _query(address(usdc), optionToken, true), inRegs, _args(ASK), ""
        );
        assertEq(out.balanceIn, inRegs.balanceIn);
        assertEq(out.balanceOut, inRegs.balanceOut);
        assertEq(out.surcharge, inRegs.surcharge);
    }
}
