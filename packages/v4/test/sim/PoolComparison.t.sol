// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {console2} from "forge-std/console2.sol";

import {Coin} from "../../src/Coin.sol";
import {WavefrontLens} from "../../src/WavefrontLens.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";
import {MockQuote} from "../mocks/MockQuote.sol";
import {WavefrontFixture} from "../utils/WavefrontFixture.sol";

/// @notice A simulation, not a test of correctness: the same traders make the same trades against a
///         wavefront coin and against an ordinary Uniswap v4 pool of the same starting price and depth,
///         and the two are printed side by side. Run with `-vv`; lines starting `CSV,` are the series.
/// @dev The ordinary pool is what a conventional launch looks like: an LP deposits the whole coin supply
///      and 100,000 USDC of their own money across the full range, with no hook. The wavefront coin
///      launches with the same supply and 100,000 USDC of *virtual* quote, and nobody's money.
contract PoolComparisonSim is WavefrontFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant TRADERS = 8;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    address internal lp = makeAddr("lp");
    address[TRADERS] internal traders;

    /// @dev An ordinary pool and its coin.
    struct Plain {
        MockQuote coin;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 lpCoin;
        uint256 lpQuote;
    }

    struct Totals {
        uint256 paidIn;
        uint256 wfOut;
        uint256 plainOut;
        uint256 wfPeak;
        uint256 plainPeak;
    }

    function setUp() public {
        _deployV4();
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        for (uint256 i; i < TRADERS; ++i) {
            traders[i] = makeAddr(string.concat("trader", vm.toString(i)));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            THE ORDINARY POOL
    //////////////////////////////////////////////////////////////*/

    /// @dev A hookless pool at wavefront's launch price, with the whole supply and 100,000 USDC from `lp`
    ///      across the full range.
    function _newPlain(uint24 fee, int24 spacing) internal returns (Plain memory p) {
        // like a wavefront coin, the coin sorts below USDC so that price reads as USDC per coin
        do {
            p.coin = new MockQuote("Plain", "PLAIN", 18);
        } while (address(p.coin) >= address(quote));
        p.key = PoolKey({
            currency0: Currency.wrap(address(p.coin)),
            currency1: Currency.wrap(address(quote)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
        manager.initialize(p.key, uint160(Math.sqrt(FullMath.mulDiv(VIRTUAL_QUOTE, 1 << 192, COIN_SUPPLY))));

        p.tickLower = TickMath.minUsableTick(spacing);
        p.tickUpper = TickMath.maxUsableTick(spacing);
        p.liquidity = uint128(Math.sqrt(VIRTUAL_QUOTE * COIN_SUPPLY));
        // a hair more than needed, for the pool's rounding; what is used is read back from the delta
        p.coin.mint(lp, COIN_SUPPLY + COIN_SUPPLY / 1e6);
        quote.mint(lp, VIRTUAL_QUOTE + VIRTUAL_QUOTE / 1e6);
        vm.startPrank(lp);
        p.coin.approve(address(lpRouter), type(uint256).max);
        quote.approve(address(lpRouter), type(uint256).max);
        BalanceDelta delta = lpRouter.modifyLiquidity(
            p.key, ModifyLiquidityParams(p.tickLower, p.tickUpper, int256(uint256(p.liquidity)), 0), ""
        );
        vm.stopPrank();
        p.lpCoin = uint256(uint128(-delta.amount0()));
        p.lpQuote = uint256(uint128(-delta.amount1()));
    }

    function _plainBuy(Plain memory p, address buyer, uint256 quoteIn) internal returns (uint256 coinOut) {
        quote.mint(buyer, quoteIn);
        vm.startPrank(buyer);
        quote.approve(address(swapRouter), quoteIn);
        BalanceDelta delta = swapRouter.swap(
            p.key,
            SwapParams(false, -int256(quoteIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        coinOut = uint256(uint128(delta.amount0()));
    }

    function _plainSell(Plain memory p, address seller, uint256 coinIn) internal returns (uint256 quoteOut) {
        vm.startPrank(seller);
        p.coin.approve(address(swapRouter), coinIn);
        BalanceDelta delta = swapRouter.swap(
            p.key,
            SwapParams(true, -int256(coinIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        quoteOut = uint256(uint128(delta.amount1()));
    }

    /// @dev External so that a sale into a pool with no liquidity left can be caught rather than abort.
    function plainSell(Plain memory p, address seller, uint256 coinIn) external returns (uint256) {
        return _plainSell(p, seller, coinIn);
    }

    /// @dev The LP withdraws everything, fees included.
    function _plainExit(Plain memory p) internal returns (uint256 coinOut, uint256 quoteOut) {
        vm.prank(lp);
        BalanceDelta delta = lpRouter.modifyLiquidity(
            p.key, ModifyLiquidityParams(p.tickLower, p.tickUpper, -int256(uint256(p.liquidity)), 0), ""
        );
        coinOut = uint256(uint128(delta.amount0()));
        quoteOut = uint256(uint128(delta.amount1()));
    }

    /// @dev USDC per whole coin, 18 decimals, like the lens reports.
    function _plainPrice(Plain memory p) internal view returns (uint256) {
        (uint160 sqrtPrice,,,) = IPoolManager(address(manager)).getSlot0(p.key.toId());
        return FullMath.mulDiv(FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 96), 1e30, 1 << 96);
    }

    /*//////////////////////////////////////////////////////////////
                               THE LONG PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice 600 trades in three phases (a pump, a choppy middle, a sell-off), then everyone exits.
    function test_sim_samePathOnBothPools() public {
        (Coin coin,) = _launch(creator, 0);
        Plain memory plain = _newPlain(20_000, 200);
        Totals memory t;

        console2.log("CSV,step,phase,wavefront_price,wavefront_floor,plain_price,wavefront_real_quote,wavefront_supply");
        _row(coin, plain, 0, 0);
        for (uint256 i; i < 600; ++i) {
            uint256 phase = i < 150 ? 0 : i < 450 ? 1 : 2;
            uint256 sellPct = phase == 0 ? 15 : phase == 1 ? 50 : 85;
            uint256 r = uint256(keccak256(abi.encode("path", i)));
            address trader = traders[r % TRADERS];
            if ((r >> 8) % 100 < sellPct && coin.balanceOf(trader) != 0 && plain.coin.balanceOf(trader) != 0) {
                uint256 pct = 1 + ((r >> 16) % 100);
                t.wfOut += _sell(coin, trader, (coin.balanceOf(trader) * pct) / 100);
                t.plainOut += _plainSell(plain, trader, (plain.coin.balanceOf(trader) * pct) / 100);
            } else {
                // between 10 and about 40,000 USDC, evenly spread across orders of magnitude
                uint256 amount = (10 * ONE_USDC) << ((r >> 16) % 12);
                amount += (amount * ((r >> 32) % 100)) / 100;
                _buy(coin, trader, amount);
                _plainBuy(plain, trader, amount);
                t.paidIn += amount;
            }
            _row(coin, plain, i + 1, phase);
            uint256 wfPrice = lens.getCoinData(address(coin), address(0)).marketPrice;
            if (wfPrice > t.wfPeak) t.wfPeak = wfPrice;
            if (_plainPrice(plain) > t.plainPeak) t.plainPeak = _plainPrice(plain);
        }

        // everyone leaves
        for (uint256 i; i < TRADERS; ++i) {
            if (coin.balanceOf(traders[i]) != 0) t.wfOut += _sell(coin, traders[i], coin.balanceOf(traders[i]));
            if (plain.coin.balanceOf(traders[i]) != 0) {
                t.plainOut += _plainSell(plain, traders[i], plain.coin.balanceOf(traders[i]));
            }
        }
        _row(coin, plain, 601, 3);
        _summary(coin, plain, t);
    }

    function _row(Coin coin, Plain memory plain, uint256 step, uint256 phase) internal view {
        WavefrontLens.CoinData memory d = lens.getCoinData(address(coin), address(0));
        console2.log(
            string.concat(
                "CSV,",
                vm.toString(step),
                ",",
                vm.toString(phase),
                ",",
                vm.toString(d.marketPrice),
                ",",
                vm.toString(d.floorPrice),
                ",",
                vm.toString(_plainPrice(plain)),
                ",",
                vm.toString(d.realQuote),
                ",",
                vm.toString(d.supply)
            )
        );
    }

    function _summary(Coin coin, Plain memory plain, Totals memory t) internal {
        WavefrontLens.CoinData memory d = lens.getCoinData(address(coin), address(0));
        IWavefrontHook.Market memory m = _market(coin);
        console2.log("SUM,launch_price", FullMath.mulDiv(VIRTUAL_QUOTE, 1e30, COIN_SUPPLY));
        console2.log("SUM,paid_in_by_buyers", t.paidIn);
        console2.log("SUM,wavefront_paid_to_sellers", t.wfOut);
        console2.log("SUM,plain_paid_to_sellers", t.plainOut);
        console2.log("SUM,wavefront_peak_price", t.wfPeak);
        console2.log("SUM,plain_peak_price", t.plainPeak);
        console2.log("SUM,wavefront_price_after_exit", d.marketPrice);
        console2.log("SUM,wavefront_floor_after_exit", d.floorPrice);
        console2.log("SUM,plain_price_after_exit", _plainPrice(plain));
        console2.log("SUM,wavefront_supply_after_exit", d.supply);
        console2.log("SUM,wavefront_real_quote_left", d.realQuote + m.pendingHeal);
        console2.log("SUM,wavefront_team_fees_quote", hook.feesOwed(address(quote), creator));
        console2.log("SUM,wavefront_treasury_fees_quote", hook.feesOwed(address(quote), treasury));
        console2.log("SUM,wavefront_team_fees_coin", hook.feesOwed(address(coin), creator));
        console2.log("SUM,wavefront_treasury_fees_coin", hook.feesOwed(address(coin), treasury));
        (uint256 lpCoin, uint256 lpQuote) = _plainExit(plain);
        console2.log("SUM,plain_lp_put_in_quote", plain.lpQuote);
        console2.log("SUM,plain_lp_took_out_quote", lpQuote);
        console2.log("SUM,plain_lp_put_in_coin", plain.lpCoin);
        console2.log("SUM,plain_lp_took_out_coin", lpCoin);
    }

    /// @notice The same 600 trades on wavefront coins launched at 1%, 2% and 5%, each beside an ordinary
    ///         pool charging the same fee.
    function test_sim_samePathAtEachFee() public {
        uint24[3] memory fees = [uint24(10_000), 20_000, 50_000];
        for (uint256 f; f < fees.length; ++f) {
            IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
            params.fee = fees[f];
            (Coin coin,) = _launchWith(creator, params, 0);
            Plain memory plain = _newPlain(fees[f], 200);
            Totals memory t;
            for (uint256 i; i < 600; ++i) {
                uint256 sellPct = i < 150 ? 15 : i < 450 ? 50 : 85;
                uint256 r = uint256(keccak256(abi.encode("path", i)));
                address trader = traders[r % TRADERS];
                if ((r >> 8) % 100 < sellPct && coin.balanceOf(trader) != 0 && plain.coin.balanceOf(trader) != 0) {
                    uint256 pct = 1 + ((r >> 16) % 100);
                    t.wfOut += _sell(coin, trader, (coin.balanceOf(trader) * pct) / 100);
                    t.plainOut += _plainSell(plain, trader, (plain.coin.balanceOf(trader) * pct) / 100);
                } else {
                    uint256 amount = (10 * ONE_USDC) << ((r >> 16) % 12);
                    amount += (amount * ((r >> 32) % 100)) / 100;
                    _buy(coin, trader, amount);
                    _plainBuy(plain, trader, amount);
                    t.paidIn += amount;
                }
            }
            for (uint256 i; i < TRADERS; ++i) {
                if (coin.balanceOf(traders[i]) != 0) t.wfOut += _sell(coin, traders[i], coin.balanceOf(traders[i]));
                if (plain.coin.balanceOf(traders[i]) != 0) {
                    t.plainOut += _plainSell(plain, traders[i], plain.coin.balanceOf(traders[i]));
                }
            }
            WavefrontLens.CoinData memory d = lens.getCoinData(address(coin), address(0));
            console2.log("FEE,fee_bps", fees[f] / 100);
            console2.log("FEE,paid_in_wfOut_plainOut", t.paidIn, t.wfOut, t.plainOut);
            console2.log("FEE,floor_after_plainprice_after", d.floorPrice, _plainPrice(plain));
            console2.log("FEE,supply_after", d.supply);
            console2.log(
                "FEE,team_plus_treasury_quote",
                hook.feesOwed(address(quote), creator) + hook.feesOwed(address(quote), treasury)
            );
            // fees accrue per token across coins; claim so the next fee level starts from zero
            hook.claimFees(address(quote), creator);
            hook.claimFees(address(quote), treasury);
        }
    }

    /// @notice A buy straight followed by a sell, on wavefront coins at each fee.
    function test_sim_roundTripAtEachFee() public {
        uint24[3] memory fees = [uint24(10_000), 20_000, 50_000];
        for (uint256 f; f < fees.length; ++f) {
            IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
            params.fee = fees[f];
            (Coin coin,) = _launchWith(creator, params, 0);
            uint256 bought = _buy(coin, alice, 10_000 * ONE_USDC);
            console2.log("TRIPFEE,fee_bps_back_of_10000usdc", fees[f] / 100, _sell(coin, alice, bought));
        }
    }

    /*//////////////////////////////////////////////////////////////
                             SINGLE SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice What one buyer gets for the same money, and what it costs to buy and sell straight back.
    function test_sim_priceImpactAndRoundTrip() public {
        uint256[4] memory sizes = [uint256(100), 1000, 10_000, 100_000];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amount = sizes[i] * ONE_USDC;
            (Coin coin,) = _launch(creator, 0);
            Plain memory two = _newPlain(20_000, 200);
            Plain memory point3 = _newPlain(3000, 60);

            uint256 wfCoins = _buy(coin, alice, amount);
            uint256 twoCoins = _plainBuy(two, alice, amount);
            uint256 point3Coins = _plainBuy(point3, alice, amount);
            console2.log("TRIP,buy_usdc", sizes[i]);
            console2.log("TRIP,coins_wavefront_plain2_plain03", wfCoins / 1e18, twoCoins / 1e18, point3Coins / 1e18);
            console2.log(
                "TRIP,back_wavefront_plain2_plain03",
                _sell(coin, alice, wfCoins),
                _plainSell(two, alice, twoCoins),
                _plainSell(point3, alice, point3Coins)
            );
        }
    }

    /// @notice The LP of an ordinary pool withdraws at the top. On wavefront there is nobody who can.
    function test_sim_liquidityPulledAtTheTop() public {
        (Coin coin,) = _launch(creator, 0);
        Plain memory plain = _newPlain(20_000, 200);
        uint256 paid;
        for (uint256 i; i < TRADERS; ++i) {
            _buy(coin, traders[i], 25_000 * ONE_USDC);
            _plainBuy(plain, traders[i], 25_000 * ONE_USDC);
            paid += 25_000 * ONE_USDC;
        }
        console2.log("RUG,paid_in_by_holders", paid);
        console2.log(
            "RUG,price_before_wavefront_plain",
            lens.getCoinData(address(coin), address(0)).marketPrice,
            _plainPrice(plain)
        );

        (, uint256 lpQuote) = _plainExit(plain);
        console2.log("RUG,plain_lp_put_in_then_walked_away_with", plain.lpQuote, lpQuote);

        uint256 wfOut;
        uint256 plainOut;
        for (uint256 i; i < TRADERS; ++i) {
            wfOut += _sell(coin, traders[i], coin.balanceOf(traders[i]));
            // with the liquidity gone a sale returns nothing, or reverts once the price is at the bottom
            vm.stopPrank();
            try this.plainSell(plain, traders[i], plain.coin.balanceOf(traders[i])) returns (uint256 out) {
                plainOut += out;
            } catch {}
        }
        console2.log("RUG,holders_got_back_wavefront_plain", wfOut, plainOut);
        console2.log("RUG,wavefront_floor_after", lens.getCoinData(address(coin), address(0)).floorPrice);
    }
}
