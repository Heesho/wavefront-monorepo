// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Coin} from "../src/Coin.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice What the lens tells a front end must be what the pool does and what the hook's books say.
contract WavefrontLensTest is WavefrontFixture {
    uint256 internal constant ONE_USDC = 1e6;
    /// @dev The most Uniswap governance can charge in either direction: 0.1%, in hundredths of a bip.
    uint24 internal constant MAX_PROTOCOL_FEE = 1000;
    /// @dev Raw quote units the PoolManager may hold beyond the hook's books after a few operations:
    ///      v4's own rounding, a raw unit or so per swap or position change. 0.000064 USDC.
    uint256 internal constant DUST = 64;

    function setUp() public {
        _deployV4();
    }

    /*//////////////////////////////////////////////////////////////
                                  QUOTES
    //////////////////////////////////////////////////////////////*/

    function test_poolManager_isTheHooks() public view {
        assertEq(address(lens.poolManager()), address(manager));
    }

    function test_quotes_noProtocolFee() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _assertQuotesMatchExecution(coin, 10_000 * ONE_USDC, 5000);
    }

    /// @notice With the protocol fee on, a trade returns less than the LP fee alone would leave, and
    ///         the lens must say so.
    function test_quotes_protocolFeeBothDirections() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        uint256 buyQuoteBefore = lens.quoteBuy(address(coin), 10_000 * ONE_USDC);

        _setProtocolFee(coin, MAX_PROTOCOL_FEE, MAX_PROTOCOL_FEE);
        assertLt(lens.quoteBuy(address(coin), 10_000 * ONE_USDC), buyQuoteBefore, "buy quote ignores the protocol fee");

        uint256 bought = _assertBuyQuoteMatches(coin, 10_000 * ONE_USDC);

        // the sell side on its own: the same sale quoted with the fee off and on
        _setProtocolFee(coin, 0, 0);
        uint256 sellQuoteWithout = lens.quoteSell(address(coin), bought / 2);
        _setProtocolFee(coin, MAX_PROTOCOL_FEE, MAX_PROTOCOL_FEE);
        assertLt(lens.quoteSell(address(coin), bought / 2), sellQuoteWithout, "sell quote ignores the protocol fee");
        _assertSellQuoteMatches(coin, bought / 2);
    }

    /// @notice The protocol fee is set per direction; each quote must use its own.
    function test_quotes_protocolFeeOnSellsOnly() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        uint256 buyQuoteBefore = lens.quoteBuy(address(coin), 10_000 * ONE_USDC);

        _setProtocolFee(coin, MAX_PROTOCOL_FEE, 0);
        assertEq(
            lens.quoteBuy(address(coin), 10_000 * ONE_USDC), buyQuoteBefore, "a sell-side fee changed the buy quote"
        );
        _assertQuotesMatchExecution(coin, 10_000 * ONE_USDC, 5000);
    }

    function test_quotes_protocolFeeOnBuysOnly() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        uint256 bought = _buy(coin, alice, 10_000 * ONE_USDC);
        uint256 sellQuoteBefore = lens.quoteSell(address(coin), bought / 2);

        _setProtocolFee(coin, 0, MAX_PROTOCOL_FEE);
        assertEq(lens.quoteSell(address(coin), bought / 2), sellQuoteBefore, "a buy-side fee changed the sell quote");
        _assertQuotesMatchExecution(coin, 10_000 * ONE_USDC, 5000);
    }

    function testFuzz_quotes_matchExecution_anyProtocolFee(
        uint256 quoteIn,
        uint256 sellBps,
        uint24 sellFee,
        uint24 buyFee,
        uint24 lpFee
    ) public {
        quoteIn = bound(quoteIn, ONE_USDC, 1_000_000 * ONE_USDC);
        sellBps = bound(sellBps, 1, 10_000);
        sellFee = uint24(bound(sellFee, 0, MAX_PROTOCOL_FEE));
        buyFee = uint24(bound(buyFee, 0, MAX_PROTOCOL_FEE));

        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.fee = uint24(bound(lpFee, hook.MIN_FEE(), hook.MAX_FEE()));
        (Coin coin,) = _launchWith(creator, params, 1000 * ONE_USDC);
        _setProtocolFee(coin, sellFee, buyFee);

        _assertQuotesMatchExecution(coin, quoteIn, sellBps);
    }

    function test_quotes_unknownCoinAndZeroAmounts() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        assertEq(lens.quoteBuy(address(coin), 0), 0);
        assertEq(lens.quoteSell(address(coin), 0), 0);
        assertEq(lens.quoteBuy(address(0xdead), ONE_USDC), 0);
        assertEq(lens.quoteSell(address(0xdead), 1e18), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                REAL QUOTE
    //////////////////////////////////////////////////////////////*/

    /// @notice `realQuote` is the hook's own count of the quote behind the curve: what the position
    ///         holds, what waits idle, and what is lent out. It is checked two ways: against the
    ///         hook's formula, and against the tokens the PoolManager physically holds.
    function test_realQuote_matchesTheBooks_afterBuyAndBorrow() public {
        (Coin coin,) = _launch(creator, 100_000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        uint256 beforeBorrow = lens.getCoinData(address(coin), address(0)).realQuote;
        _assertRealQuoteMatchesBooks(coin);

        _borrow(coin, alice, hook.creditOf(address(coin), alice) / 2);
        IWavefrontHook.Market memory m = _market(coin);
        assertGt(m.totalDebt, 0);
        assertGt(m.lowerTick, m.floorTick, "the loan did not raise the lower tick");
        // idle quote is what the lens used to leave out; the check below would catch that
        assertGt(m.idleQuote, DUST);
        _assertRealQuoteMatchesBooks(coin);

        // lending moves quote out of the position without changing what backs the curve
        uint256 afterBorrow = lens.getCoinData(address(coin), address(0)).realQuote;
        assertApproxEqAbs(afterBorrow, beforeBorrow, 2, "a loan changed the quote backing the curve");

        _repay(coin, alice, m.totalDebt);
        _assertRealQuoteMatchesBooks(coin);
        assertApproxEqAbs(lens.getCoinData(address(coin), address(0)).realQuote, beforeBorrow, 4);
    }

    function testFuzz_realQuote_matchesTheBooks(uint256 firstBuy, uint256 secondBuy, uint256 borrowBps, uint256 sellBps)
        public
    {
        firstBuy = bound(firstBuy, 100 * ONE_USDC, 1_000_000 * ONE_USDC);
        secondBuy = bound(secondBuy, ONE_USDC, 1_000_000 * ONE_USDC);
        borrowBps = bound(borrowBps, 0, 10_000);
        sellBps = bound(sellBps, 0, 10_000);

        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, firstBuy);
        uint256 bobCoins = _buy(coin, bob, secondBuy);
        _assertRealQuoteMatchesBooks(coin);

        uint256 amount = (hook.creditOf(address(coin), alice) * borrowBps) / 10_000;
        if (amount != 0) _borrow(coin, alice, amount);
        _assertRealQuoteMatchesBooks(coin);

        uint256 coinIn = (bobCoins * sellBps) / 10_000;
        if (coinIn != 0) _sell(coin, bob, coinIn);
        _assertRealQuoteMatchesBooks(coin);
    }

    /// @notice A coin nobody has bought has no real quote behind it.
    function test_realQuote_zeroBeforeTheFirstBuy() public {
        (Coin coin,) = _launch(creator, 0);
        assertEq(lens.getCoinData(address(coin), address(0)).realQuote, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Switches the pool's protocol fee on, as Uniswap governance would.
    function _setProtocolFee(Coin coin, uint24 sellFee, uint24 buyFee) internal {
        if (manager.protocolFeeController() != address(this)) {
            vm.prank(owner);
            manager.setProtocolFeeController(address(this));
        }
        // packed as v4 packs it: coin-for-quote (a sell) in the low 12 bits, quote-for-coin above
        manager.setProtocolFee(hook.poolKey(address(coin)), sellFee | (buyFee << 12));
    }

    function _assertQuotesMatchExecution(Coin coin, uint256 quoteIn, uint256 sellBps) internal {
        uint256 bought = _assertBuyQuoteMatches(coin, quoteIn);
        uint256 coinIn = (bought * sellBps) / 10_000;
        if (coinIn != 0) _assertSellQuoteMatches(coin, coinIn);
    }

    /// @dev The pool fills a trade in several internal steps, each rounding by a wei, so quotes agree
    ///      to a part in a billion rather than exactly (the same tolerance the hook's own suite uses).
    ///      The protocol fee is at least a part in a million of the trade, so a quote that left it out
    ///      could not pass.
    function _assertBuyQuoteMatches(Coin coin, uint256 quoteIn) internal returns (uint256 bought) {
        uint256 quoted = lens.quoteBuy(address(coin), quoteIn);
        bought = _buy(coin, alice, quoteIn);
        assertApproxEqRel(bought, quoted, 1e9, "buy quote");
    }

    function _assertSellQuoteMatches(Coin coin, uint256 coinIn) internal {
        uint256 quoted = lens.quoteSell(address(coin), coinIn);
        assertApproxEqAbs(_sell(coin, alice, coinIn), quoted, 2 + quoted / 1e9, "sell quote");
    }

    function _assertRealQuoteMatchesBooks(Coin coin) internal view {
        IWavefrontHook.Market memory m = _market(coin);
        uint256 real = lens.getCoinData(address(coin), address(0)).realQuote;

        // the hook's own formula (WavefrontHook._ratchetDue)
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
        uint160 sqrtPrice = hook.sqrtPriceX96(address(coin));
        uint256 inPosition =
            sqrtPrice > sqrtLower ? SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, m.liquidity, false) : 0;
        assertEq(real, inPosition + m.idleQuote + m.totalDebt, "lens and hook disagree");

        // The tokens themselves. Everything the PoolManager holds of the quote is either in the
        // position or held for the hook as claims; of the claims, idle quote backs the curve, and
        // the rest is pending heal and fees owed. v4 rounds every swap and every change to a position
        // in the pool's favour, so the PoolManager also holds a raw unit or so per operation that
        // belongs to nobody (10 to 20 raw units after the handful of operations here). The lens must
        // never count more than is there, and must not miss anything larger than that dust.
        address token = m.quote;
        uint256 held = _quoteOf(coin).balanceOf(address(manager)) - manager.protocolFeesAccrued(Currency.wrap(token));
        uint256 notBacking = m.pendingHeal + hook.feesOwed(token, creator) + hook.feesOwed(token, treasury);
        uint256 physical = held - notBacking + m.totalDebt;
        assertLe(real, physical, "the lens counts quote that is not there");
        assertLe(physical - real, DUST, "quote in the PoolManager that the lens does not count");
    }
}
